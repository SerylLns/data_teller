module DataTeller
  # Checks the row-level security of the database role (T39, ADR 0005 D7), for `rake data_teller:check`: never at boot (ADR 0004 D6).
  # Each table the role can read must have DataTeller's policies, and the role must see none of its rows without a tenant, or
  # for a tenant that does not exist. Tried for real, not only read from the catalog: a policy edited by hand still has its name.
  # On an empty table the second part proves nothing; the first still holds.
  class RowSecurityValidator
    NO_UUID = "00000000-0000-0000-0000-000000000000".freeze

    def initialize(config:, registry:)
      @config = config
      @role = config.database_role
      @registry = registry
    end

    def call
      return [] unless @config.row_security && @role

      policies = RowPolicies.new(registry: @registry, tenant_model_name: @config.tenant_model_name, role: @role)
      return policies.errors if policies.errors.any?

      ActiveRecord::Base.with_connection do |connection|
        @connection = connection
        next [ "row_security: #{@role} has BYPASSRLS, row-level security does not apply to it" ] if bypasses?

        readable = ReaderGrants.new(registry: @registry, tenant_model_name: @config.tenant_model_name).columns.keys
        unprotected = (readable - policies.conditions.keys).map { |table| "row_security: #{@role} can read #{table}, which has no row policy" }
        unprotected + policies.conditions.keys.flat_map { |table| problems_of(table) }
      end
    rescue ActiveRecord::ActiveRecordError => e
      [ "cannot read the database to check row_security: #{e.class}" ]
    end

    private

    def problems_of(table)
      structure = structural_problems(table)
      return structure if structure.any?

      [ rows_without_tenant(table), rows_of_absent_tenant(table) ].compact
    end

    def structural_problems(table)
      regclass = "to_regclass(#{@connection.quote(@connection.quote_table_name(table))})"
      enabled, owner = @connection.select_rows("SELECT relrowsecurity, pg_get_userbyid(relowner) FROM pg_class WHERE oid = #{regclass}").first
      return [ "row_security: #{@role} owns #{table}, and an owner skips row-level security" ] if owner == @role
      return [ "row_security: #{table} does not have row-level security enabled: run `rake data_teller:grants` again" ] unless enabled

      found = @connection.select_rows(<<~SQL).to_h
        SELECT polname, polpermissive FROM pg_policy
        WHERE polrelid = #{regclass} AND (polroles @> ARRAY[(SELECT oid FROM pg_roles WHERE rolname = #{@connection.quote(@role)})] OR polroles = '{0}')
      SQL
      expected = { RowPolicies::TENANT => false, RowPolicies::READER_ROWS => true, RowPolicies::OTHERS => true }

      expected.filter_map do |name, permissive|
        next if found[name] == permissive

        "row_security: #{table} lacks the #{permissive ? 'permissive' : 'restrictive'} policy #{name}: run `rake data_teller:grants` again"
      end
    end

    # The policy reads a setting no one set: Postgres raises, or compares to an empty string. Either way, no row.
    def rows_without_tenant(table)
      return nil unless any_row?(table, nil)

      "row_security: #{@role} reads rows of #{table} with no tenant set"
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def rows_of_absent_tenant(table)
      return nil unless any_row?(table, absent_tenant)

      "row_security: #{@role} reads rows of #{table} for a tenant that does not exist: its policies let other tenants' rows through"
    rescue ActiveRecord::StatementInvalid => e
      "row_security: cannot check #{table} under #{@role}: #{e.class}"
    end

    def any_row?(table, tenant_id)
      ReadOnlyExecution.run(ActiveRecord::Base, timeout: SchemaValidator::SCOPE_CHECK_TIMEOUT, role: @role, tenant_id: tenant_id) do
        !@connection.select_value("SELECT 1 FROM #{@connection.quote_table_name(table)} LIMIT 1").nil?
      end
    end

    # A key of the right type that no tenant has: below the smallest integer key, or the nil UUID.
    def absent_tenant
      @absent_tenant ||= begin
        tenant = @config.tenant_model_name.constantize
        case tenant.type_for_attribute(tenant.primary_key).type
        when :integer, :bigint then (tenant.unscoped.minimum(tenant.primary_key) || 0) - 1
        when :uuid then NO_UUID
        else "data_teller_no_such_tenant"
        end
      end
    end

    def bypasses? = @connection.select_value("SELECT rolbypassrls FROM pg_roles WHERE rolname = #{@connection.quote(@role)}")
  end
end
