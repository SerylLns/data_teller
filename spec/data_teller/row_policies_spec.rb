require "rails_helper"

RSpec.describe DataTeller::RowPolicies do
  def dataset(model, tenant_path: %i[account], **members)
    DataTeller::Dataset.new(model_name: model, roles: %i[admin], tenant_path: tenant_path, **members)
  end

  def policies_for(*datasets)
    registry = DataTeller::Registry.new
    datasets.each { |one| registry.register(one) }
    described_class.new(registry: registry.freeze!, tenant_model_name: "Account", role: "data_teller_reader")
  end

  def execute(sql) = ActiveRecord::Base.with_connection { |connection| connection.execute(sql) }

  it "compares a table's tenant key to the transaction's tenant, cast to the column's type" do
    conditions = described_class.new(registry: DataTeller.registry, tenant_model_name: "Account", role: "data_teller_reader").conditions

    expect(conditions.keys).to eq(DataTeller::ReaderGrants.new(registry: DataTeller.registry, tenant_model_name: "Account").columns.keys)
    expect(conditions["orders"]).to eq(%("orders"."account_id" = current_setting('data_teller.tenant_id')::bigint))
    expect(conditions["reviews"]).to eq(%(EXISTS (SELECT 1 FROM "products" WHERE "products"."id" = "reviews"."product_id")))
  end

  it "keeps the rows of a table with no tenant key whose parent is visible, and gives the parent its own policy" do
    policies = policies_for(dataset("LineItem", tenant_path: %i[order account]))

    expect(policies.conditions).to eq(
      "line_items" => %(EXISTS (SELECT 1 FROM "orders" WHERE "orders"."id" = "line_items"."order_id")),
      "orders" => %("orders"."account_id" = current_setting('data_teller.tenant_id')::bigint)
    )
  end

  it "uses the primary key on the tenant model itself" do
    expect(policies_for(dataset("Account", tenant_path: nil)).conditions)
      .to eq("accounts" => %("accounts"."id" = current_setting('data_teller.tenant_id')::bigint))
  end

  it "refuses two tenant paths to one table, which would need two conditions" do
    policies = policies_for(dataset("LineItem", tenant_path: %i[order account]), dataset("Order", tenant_path: %i[customer account]))

    expect(policies.errors).to contain_exactly(a_string_including("orders is reached by two tenant paths"))
    expect { policies.sql }.to raise_error(DataTeller::ConfigurationError, /two tenant paths/)
  end

  it "refuses a path that does not end on the tenant model, whose key the setting holds" do
    policies = policies_for(dataset("Order", tenant_path: %i[customer]))

    expect(policies.errors).to contain_exactly(a_string_including("must end on the primary key of Account"))
  end

  describe "a table with row security of its own" do
    it "is refused when it has policies that are not DataTeller's" do
      execute("CREATE POLICY app_tenant ON orders USING (true)")

      expect(policies_for(dataset("Order")).errors).to contain_exactly(a_string_including("orders has policies of its own (app_tenant)"))
    end

    it "is refused when it has row security on and no policy, which keeps it closed to other roles" do
      execute("ALTER TABLE orders ENABLE ROW LEVEL SECURITY")

      expect(policies_for(dataset("Order")).errors).to contain_exactly(a_string_including("already has row security"))
    end

    it "is accepted again once it holds DataTeller's policies only" do
      execute("CREATE ROLE data_teller_reader NOLOGIN") unless execute("SELECT 1 FROM pg_roles WHERE rolname = 'data_teller_reader'").any?
      execute(policies_for(dataset("Order")).sql)

      expect(policies_for(dataset("Order")).errors).to eq([])
    end
  end

  describe "#sql" do
    subject(:sql) { policies_for(dataset("Order")).sql }

    it "applies the tenant condition to the role as a restrictive policy, which no permissive one can widen" do
      expect(sql).to include(%(CREATE POLICY data_teller_tenant ON "orders" AS RESTRICTIVE FOR SELECT TO "data_teller_reader" USING ("orders"."account_id" = current_setting('data_teller.tenant_id')::bigint);))
    end

    it "leaves other roles every row, for reading and for writing" do
      expect(sql).to include(%(CREATE POLICY data_teller_others ON "orders" AS PERMISSIVE FOR ALL TO PUBLIC USING (current_user <> 'data_teller_reader') WITH CHECK (current_user <> 'data_teller_reader');))
    end

    it "can be run again: each policy is dropped before it is created" do
      %w[data_teller_tenant data_teller_reader_rows data_teller_others].each do |name|
        expect(sql.index(%(DROP POLICY IF EXISTS #{name} ON "orders";))).to be < sql.index(%(CREATE POLICY #{name} ON "orders"))
      end
    end
  end
end
