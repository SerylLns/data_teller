require "rails_helper"

RSpec.describe DataTeller::ReaderGrants do
  before(:all) do
    # Spec-only model on the orders table, for what the dummy app's Order does not have: a default_scope and a scope.
    Object.const_set(:SpecGrantOrder, Class.new(ApplicationRecord))
    SpecGrantOrder.class_eval do
      self.table_name = "orders"
      belongs_to :account
      belongs_to :customer
      has_many :line_items, foreign_key: :order_id

      default_scope { where.not(created_at: nil) }
      scope :touched, -> { where.not(updated_at: nil) }
    end
  end

  after(:all) { Object.send(:remove_const, :SpecGrantOrder) }

  def dataset(model, tenant_path: %i[account], **members)
    DataTeller::Dataset.new(model_name: model, roles: %i[admin], tenant_path: tenant_path, **members)
  end

  def columns_for(*datasets)
    registry = DataTeller::Registry.new
    datasets.each { |one| registry.register(one) }
    described_class.new(registry: registry.freeze!, tenant_model_name: "Account").columns
  end

  it "gives the dummy app's declarations their columns, and leaves the rest out" do
    columns = described_class.new(registry: DataTeller.registry, tenant_model_name: "Account").columns

    expect(columns).to eq(
      "customers" => %w[account_id city id name],
      "orders" => %w[account_id customer_id ordered_at ship_on status total_cents]
    )
  end

  describe "everything a query can touch" do
    subject(:columns) do
      columns_for(
        dataset("SpecGrantOrder",
                dimensions: [ DataTeller::Dimension.new(name: :status) ],
                metrics: [ DataTeller::Metric.new(name: :units, aggregation: :sum, column: :"line_items.quantity") ],
                segments: [ DataTeller::Segment.new(name: :paid, where: { status: 1, customer: nil }),
                            DataTeller::Segment.new(name: :touched, scope: :touched) ]),
        dataset("LineItem", tenant_path: %i[order account]),
        dataset("Product", dimensions: [ DataTeller::Dimension.new(name: :category) ]),
        dataset("Customer", dimensions: [ DataTeller::Dimension.new(name: :city) ])
      )
    end

    it "is the declared columns, the keys of joins and of the tenant filter, and what scopes compare" do
      expect(columns).to eq(
        # account_id: tenant. created_at: default_scope. customer_id: segment and path. id: metric path and LineItem's tenant path.
        "orders" => %w[account_id created_at customer_id id status updated_at],
        # order_id: metric path and tenant path. product_id: the path to product.category.
        "line_items" => %w[order_id product_id quantity],
        "products" => %w[account_id category id],
        "customers" => %w[account_id city id]
      )
    end

    it "never includes a column nothing declares" do
      expect(columns["orders"]).not_to include("total_cents", "ship_on", "ordered_at")
      expect(columns["customers"]).not_to include("email", "phone", "name")
      expect(columns).not_to include("accounts", "users")
    end
  end

  # line_items.order_id IN (SELECT orders.id FROM orders WHERE orders.account_id = ?)
  it "follows a tenant_path of two steps: the foreign key, then the key the parent is selected by" do
    expect(columns_for(dataset("LineItem", tenant_path: %i[order account])))
      .to eq("line_items" => %w[order_id], "orders" => %w[account_id id])
  end

  it "uses the primary key of the tenant model itself, which has no tenant_path" do
    expect(columns_for(dataset("Account", tenant_path: nil, dimensions: [ DataTeller::Dimension.new(name: :name) ])))
      .to eq("accounts" => %w[id name])
  end

  it "adds nothing for a scope the compiler would refuse" do
    SpecGrantOrder.scope :reads_raw_sql, -> { where("total_cents > 0") }

    columns = columns_for(dataset("SpecGrantOrder", segments: [ DataTeller::Segment.new(name: :raw, scope: :reads_raw_sql) ]))

    expect(columns["orders"]).not_to include("total_cents")
  ensure
    SpecGrantOrder.singleton_class.send(:remove_method, :reads_raw_sql)
  end

  describe "#sql" do
    subject(:sql) { described_class.new(registry: DataTeller.registry, tenant_model_name: "Account").sql(role: "data_teller_reader", member: "app") }

    it "creates the role if needed, makes the app's user a member, and grants from nothing" do
      expect(sql).to include(%(CREATE ROLE "data_teller_reader" NOLOGIN;))
      expect(sql).to include(%(GRANT "data_teller_reader" TO "app";))
      expect(sql.index(%(REVOKE ALL ON ALL TABLES IN SCHEMA "public" FROM "data_teller_reader";)))
        .to be < sql.index("GRANT SELECT")
      expect(sql).to include(%(GRANT SELECT ("account_id", "city", "id", "name") ON "customers" TO "data_teller_reader";))
    end

    it "grants nothing but SELECT on columns" do
      expect(sql.scan(/^GRANT .*$/).grep_v(/\AGRANT SELECT \(.+\) ON "\w+" TO|\AGRANT USAGE ON SCHEMA|\AGRANT "data_teller_reader" TO/)).to eq([])
    end
  end
end
