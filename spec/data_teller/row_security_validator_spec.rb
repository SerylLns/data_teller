require "rails_helper"

# The role and the policies are created inside the spec's transaction, and rolled back with it.
RSpec.describe DataTeller::RowSecurityValidator do
  let(:role) { "data_teller_spec_reader" }
  let(:config) do
    DataTeller::Configuration.new.tap do |c|
      c.tenant do
        model Account
        resolve { |user| user.account }
      end
      c.database_role = role
      c.row_security = true
    end
  end

  def errors = described_class.new(config: config, registry: DataTeller.registry).call
  def execute(sql) = ActiveRecord::Base.with_connection { |connection| connection.execute(sql) }

  before do
    acme = Account.create!(name: "Acme", time_zone: "UTC")
    customer = acme.customers.create!(name: "Alice", email: "alice@example.test")
    acme.orders.create!(customer: customer, status: :paid, total_cents: 100, ordered_at: Time.current)

    member = ActiveRecord::Base.with_connection { |connection| connection.select_value("SELECT current_user") }
    execute(DataTeller::ReaderGrants.new(registry: DataTeller.registry, tenant_model_name: "Account").sql(role: role, member: member))
    execute(DataTeller::RowPolicies.new(registry: DataTeller.registry, tenant_model_name: "Account", role: role).sql)
  end

  it "accepts the policies rake data_teller:grants prints" do
    expect(errors).to eq([])
  end

  it "has nothing to say when row_security is off" do
    config.row_security = false
    execute("ALTER TABLE orders DISABLE ROW LEVEL SECURITY")

    expect(errors).to eq([])
  end

  it "says when a table has row security turned off" do
    execute("ALTER TABLE orders DISABLE ROW LEVEL SECURITY")

    expect(errors).to contain_exactly(a_string_including("orders does not have row-level security enabled"))
  end

  it "says when the tenant policy is missing" do
    execute("DROP POLICY data_teller_tenant ON orders")

    expect(errors).to contain_exactly(a_string_including("orders lacks the restrictive policy data_teller_tenant"))
  end

  # The name is right, the condition is not: only running a query under the role can tell.
  it "catches a tenant policy that lets every row through" do
    execute("DROP POLICY data_teller_tenant ON orders")
    execute("CREATE POLICY data_teller_tenant ON orders AS RESTRICTIVE FOR SELECT TO #{role} USING (account_id IS NOT NULL)")

    expect(errors).to contain_exactly(
      a_string_including("reads rows of orders with no tenant set"),
      a_string_including("reads rows of orders for a tenant that does not exist")
    )
  end

  it "refuses a role that skips row-level security" do
    execute("ALTER ROLE #{role} BYPASSRLS")

    expect(errors).to contain_exactly(a_string_including("BYPASSRLS"))
  end

  it "refuses a role that owns a table, since an owner skips it too" do
    execute("ALTER TABLE customers OWNER TO #{role}")

    expect(errors).to contain_exactly(a_string_including("owns customers"))
  end

  it "runs from rake data_teller:check" do
    validator = instance_double(described_class, call: [ "row_security: spec" ])
    allow(described_class).to receive(:new).and_return(validator)

    expect(DataTeller.check(Rails.root, schema: true).errors).to eq([ "row_security: spec" ])
  end
end
