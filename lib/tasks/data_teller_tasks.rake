namespace :data_teller do
  # Must run before the environment loads: under the default :raise, the boot would die before this task can report.
  task :defer_boot do
    DataTeller.defer_boot!
  end

  desc "Print the JSON schema the LLM gets for some roles, e.g. rake \"data_teller:schema[admin,support]\""
  task :schema, [] => :environment do |_task, args|
    puts JSON.pretty_generate(DataTeller::SchemaGenerator.for_roles(args.extras))
  end

  desc "Print the SQL giving c.database_role a SELECT on the declared columns only, and its row policies with c.row_security, to review and run"
  task grants: :environment do
    role = DataTeller.config.database_role
    abort "DataTeller: set c.database_role in config/data_teller.rb first, e.g. c.database_role = \"data_teller_reader\"" unless role

    grants = DataTeller::ReaderGrants.new(registry: DataTeller.registry, tenant_model_name: DataTeller.config.tenant_model_name)
    member = ActiveRecord::Base.with_connection { |connection| connection.select_value("SELECT current_user") }
    policies = DataTeller::RowPolicies.new(registry: DataTeller.registry, tenant_model_name: DataTeller.config.tenant_model_name, role: role)
    abort "DataTeller: cannot write the row policies:\n#{policies.errors.join("\n")}" if DataTeller.config.row_security && policies.errors.any?

    print grants.sql(role: role, member: member)
    print policies.sql if DataTeller.config.row_security
  end

  desc "Validate the DataTeller declarations, columns included (run it in CI and after migrations)"
  task check: %i[defer_boot environment] do
    report = DataTeller.check(Rails.root, schema: true)
    report.warnings.each { |warning| warn "warning: #{warning}" }

    if report.ok?
      datasets = report.registry.datasets
      puts "DataTeller: OK (#{datasets.size} #{datasets.size == 1 ? 'dataset' : 'datasets'}: #{datasets.map(&:name).join(', ')})"
    else
      warn report.message
      exit 1
    end
  end
end
