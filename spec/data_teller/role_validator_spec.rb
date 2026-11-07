require "rails_helper"

# Roles are created inside the spec's transaction: rolled back with it, they never outlive the example.
RSpec.describe DataTeller::RoleValidator do
  let(:role) { "data_teller_spec_reader" }
  let(:config) { DataTeller::Configuration.new.tap { |c| c.database_role = role } }

  def errors = described_class.new(config: config, registry: DataTeller.registry).call
  def execute(sql) = ActiveRecord::Base.with_connection { |connection| connection.execute(sql) }

  def apply_grants
    member = ActiveRecord::Base.with_connection { |connection| connection.select_value("SELECT current_user") }
    execute(DataTeller::ReaderGrants.new(registry: DataTeller.registry, tenant_model_name: "Account").sql(role: role, member: member))
  end

  it "has nothing to say when no role is set" do
    config.database_role = nil

    expect(errors).to eq([])
  end

  it "accepts a role with exactly the grants rake data_teller:grants prints" do
    apply_grants

    expect(errors).to eq([])
  end

  it "says when the role does not exist" do
    expect(errors).to contain_exactly(a_string_including("does not exist", "rake data_teller:grants"))
  end

  it "refuses a superuser, which reads everything" do
    execute("CREATE ROLE #{role} SUPERUSER NOLOGIN")

    expect(errors).to contain_exactly(a_string_including("superuser"))
  end

  it "names each column the declarations need and the role cannot read" do
    apply_grants
    execute("REVOKE SELECT (total_cents) ON orders FROM #{role}")

    expect(errors).to contain_exactly(a_string_including("cannot read orders.total_cents"))
  end

  it "names each column the role can read and no declaration needs" do
    apply_grants
    execute("GRANT SELECT (email) ON customers TO #{role}")

    expect(errors).to contain_exactly(a_string_including("can read customers.email"))
  end

  # The mistake that voids the role while looking fine: a table-level grant, here through PUBLIC.
  it "sees a grant to PUBLIC, which every role has" do
    apply_grants
    execute("GRANT SELECT ON users TO PUBLIC")

    expect(errors).to include(a_string_including("can read users.email", "PUBLIC"))
  end

  it "runs from rake data_teller:check, once the declarations are valid" do
    validator = instance_double(described_class, call: [ "database_role: spec" ])
    allow(described_class).to receive(:new).and_return(validator)

    expect(DataTeller.check(Rails.root, schema: true).errors).to eq([ "database_role: spec" ])
    expect(DataTeller.check(Rails.root).errors).to eq([])
  end
end
