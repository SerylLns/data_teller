module DataTeller
  # The row-level security policies (T39, ADR 0005 D7), one per table, from each dataset's tenant_path: a table holding the
  # tenant's key compares it to the transaction's tenant; any other table keeps the rows whose parent is visible, and the
  # parent's own policy does the rest. They apply to the database role only.
  #
  # Reads the models and the database (column types, existing policies), so never at boot (ADR 0004 D6).
  class RowPolicies
    TENANT = "data_teller_tenant".freeze
    READER_ROWS = "data_teller_reader_rows".freeze
    OTHERS = "data_teller_others".freeze
    OWN = [ TENANT, READER_ROWS, OTHERS ].freeze

    def initialize(registry:, tenant_model_name:, role:)
      @registry = registry
      @tenant_class = tenant_model_name&.safe_constantize
      @role = role
    end

    # { "line_items" => %(EXISTS (SELECT 1 FROM "orders" WHERE ...)) }: the condition of each table's tenant policy.
    def conditions
      build
      @conditions
    end

    # What keeps the policies from being written. Reported by `rake data_teller:check` and `rake data_teller:grants`.
    def errors
      build
      @errors
    end

    # Printed for the developer to review and run, after the grants. Raises if there are errors: a partial set of policies
    # would leave tables open while the configuration says they are not.
    def sql
      raise ConfigurationError, errors.join("\n") if errors.any?

      ActiveRecord::Base.with_connection do |connection|
        role = connection.quote_column_name(@role)
        lines = [
          "-- Row-level security: rows of DataTeller's role are its tenant's only, whatever the SQL says. Other roles are not",
          "-- affected: #{OTHERS} keeps every row for them, and a table's owner skips row-level security anyway."
        ]
        conditions.each do |table, condition|
          quoted = connection.quote_table_name(table)
          lines.push(
            "ALTER TABLE #{quoted} ENABLE ROW LEVEL SECURITY;",
            *OWN.map { |name| "DROP POLICY IF EXISTS #{name} ON #{quoted};" },
            "CREATE POLICY #{OTHERS} ON #{quoted} AS PERMISSIVE FOR ALL TO PUBLIC USING (current_user <> #{connection.quote(@role)}) " \
              "WITH CHECK (current_user <> #{connection.quote(@role)});",
            "CREATE POLICY #{READER_ROWS} ON #{quoted} AS PERMISSIVE FOR SELECT TO #{role} USING (true);",
            # Restrictive: ANDed with every other policy, so that no permissive policy, ours or not, can widen it.
            "CREATE POLICY #{TENANT} ON #{quoted} AS RESTRICTIVE FOR SELECT TO #{role} USING (#{condition});"
          )
        end
        lines.join("\n") + "\n"
      end
    end

    private

    def build
      return if @conditions

      @conditions = {}
      @errors = []
      return @errors << "row_security: the tenant model is not a model" unless @tenant_class

      ActiveRecord::Base.with_connection do |connection|
        @connection = connection
        @registry.datasets.each do |dataset|
          klass = ModelLookup.active_record_class(dataset.model_name)
          add_path(klass, dataset.tenant_path, dataset.name) if klass
        end
        check_tables_have_no_policies_of_their_own
      end
      @conditions = @conditions.sort.to_h.freeze
      @errors.freeze
    end

    def add_path(klass, path, dataset_name)
      return add(klass, column_is_tenant(klass, klass.primary_key), dataset_name) if path.nil?

      step, *rest = path
      reflection = klass.reflect_on_association(step)
      return unless reflection&.belongs_to? # the boot refuses it

      if rest.empty?
        add(klass, column_is_tenant(klass, reflection.foreign_key), dataset_name) if tenant_key?(reflection, klass, dataset_name)
      else
        add(klass, parent_visible(klass, reflection), dataset_name)
        add_path(reflection.klass, rest, dataset_name)
      end
    end

    # The setting is text: cast to the column's own type, so that the comparison can use its index.
    def column_is_tenant(klass, column)
      sql_type = klass.columns_hash.fetch(column.to_s).sql_type
      "#{qualified(klass, column)} = current_setting(#{@connection.quote(ReadOnlyExecution::TENANT_SETTING)})::#{sql_type}"
    end

    # Under the role, the parent table has its own policy: a parent of another tenant is not visible, so neither is the row.
    def parent_visible(klass, reflection)
      parent = reflection.klass
      "EXISTS (SELECT 1 FROM #{@connection.quote_table_name(parent.table_name)} " \
        "WHERE #{qualified(parent, reflection.association_primary_key)} = #{qualified(klass, reflection.foreign_key)})"
    end

    # The setting holds the tenant's primary key (QueryRunner): a path ending on another of its columns would compare the wrong thing.
    def tenant_key?(reflection, klass, dataset_name)
      return true if reflection.klass == @tenant_class && reflection.association_primary_key.to_s == @tenant_class.primary_key.to_s

      @errors << "row_security: dataset #{dataset_name}: the tenant_path of #{klass.name} must end on the primary key of #{@tenant_class.name}"
      false
    end

    # One policy per table: two paths would need two conditions, and choosing one would be a guess.
    def add(klass, condition, dataset_name)
      table = klass.table_name
      existing = @conditions[table]
      return @conditions[table] = condition if existing.nil? || existing == condition

      @errors << "row_security: dataset #{dataset_name}: the table #{table} is reached by two tenant paths; give its datasets the same tenant_path"
    end

    # Combining with the app's own row security cannot be done safely from here: ours would OR into its permissive policies,
    # enabling row security would switch on policies it had left off, and #{OTHERS} would open a table it keeps closed.
    def check_tables_have_no_policies_of_their_own
      @conditions.each_key do |table|
        regclass = "to_regclass(#{@connection.quote(@connection.quote_table_name(table))})"
        names = @connection.select_values("SELECT polname FROM pg_policy WHERE polrelid = #{regclass}")
        enabled = @connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = #{regclass}")
        foreign = names - OWN

        if foreign.any?
          @errors << "row_security: the table #{table} has policies of its own (#{foreign.sort.join(', ')}); combine DataTeller's with them by hand"
        elsif enabled && names.empty?
          @errors << "row_security: the table #{table} already has row security, with no policy; combine DataTeller's with it by hand"
        end
      end
    end

    def qualified(klass, column)
      "#{@connection.quote_table_name(klass.table_name)}.#{@connection.quote_column_name(column)}"
    end
  end
end
