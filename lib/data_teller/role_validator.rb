module DataTeller
  # Checks the database role against the declarations (T37, ADR 0005 D6), for `rake data_teller:check`: it reads the database,
  # so never at boot (ADR 0004 D6). Too few grants refuse legitimate queries; too many, and the role protects nothing, while
  # the developer believes it does. Both are errors.
  class RoleValidator
    def initialize(config:, registry:)
      @role = config.database_role
      @tenant_model_name = config.tenant_model_name
      @registry = registry
    end

    def call
      return [] unless @role

      ActiveRecord::Base.with_connection do |connection|
        @connection = connection
        next [ "database_role #{@role} does not exist: run `rake data_teller:grants` and apply the SQL it prints" ] unless exists?
        next [ "database_role #{@role} is a superuser, it reads every column: give DataTeller a role of its own" ] if superuser?
        next [ "database_role: #{current_user} cannot switch to #{@role}: GRANT #{@role} TO #{current_user}" ] unless can_switch?

        missing_columns + extra_columns
      end
    rescue ActiveRecord::ActiveRecordError => e
      # Only the class, as in SchemaValidator: this output goes to CI logs.
      [ "cannot read the database to check database_role: #{e.class}" ]
    end

    private

    def exists? = @connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = #{@connection.quote(@role)}") == 1
    def superuser? = @connection.select_value("SELECT rolsuper FROM pg_roles WHERE rolname = #{@connection.quote(@role)}")
    def current_user = @connection.select_value("SELECT current_user")

    # Tried for real, the way queries do it: membership alone does not say whether SET ROLE is allowed (Postgres 16 and later).
    def can_switch?
      ReadOnlyExecution.run(ActiveRecord::Base, timeout: SchemaValidator::SCOPE_CHECK_TIMEOUT, role: @role) { true }
    rescue ActiveRecord::StatementInvalid
      false
    end

    def missing_columns
      (needed - readable).map { |table, column| "database_role #{@role} cannot read #{table}.#{column}, which the declarations need: run `rake data_teller:grants` again" }
    end

    def extra_columns
      (readable - needed).map do |table, column|
        "database_role #{@role} can read #{table}.#{column}, which no declaration needs: run `rake data_teller:grants` again, " \
          "and if it stays, revoke it from PUBLIC or from a role #{@role} is a member of"
      end
    end

    # Table names as Postgres prints them under the current search_path, so that both sides compare the same way.
    def needed
      @needed ||= ReaderGrants.new(registry: @registry, tenant_model_name: @tenant_model_name).columns.flat_map do |table, columns|
        name = @connection.select_value("SELECT to_regclass(#{@connection.quote(@connection.quote_table_name(table))})::text")
        columns.map { |column| [ name || table, column ] }
      end.to_set
    end

    # Base tables only, in the schemas of the search_path: an extension's view granted to PUBLIC is not the app's data.
    def readable
      @readable ||= @connection.select_rows(<<~SQL).to_set
        SELECT c.oid::regclass::text, a.attname
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
          AND n.nspname = ANY (current_schemas(false))
          AND has_column_privilege(#{@connection.quote(@role)}, c.oid, a.attnum, 'SELECT')
      SQL
    end
  end
end
