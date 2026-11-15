require "rails_helper"

# Real rows on two tenants: the only proof of isolation that counts is what actually comes out of the database.
RSpec.describe DataTeller::QueryRunner do
  before(:all) do
    # Spec-only model, for what the dummy app's clean domain does not have. Hostile scopes are in spec/security.
    Object.const_set(:SpecHostile, Class.new(ApplicationRecord))
    SpecHostile.class_eval do
      self.table_name = "orders"
      belongs_to :account
      belongs_to :customer

      scope :paid_ones, -> { where(status: 1) }
      scope :shipped_ones, -> { where(status: 2) }
    end
  end

  after(:all) { Object.send(:remove_const, :SpecHostile) }

  include ActiveSupport::Testing::TimeHelpers

  before { travel_to(Time.utc(2026, 11, 4, 12)) }
  after { travel_back }

  let(:user_class) { Struct.new(:account, :roles) }
  let(:acme) { Account.create!(name: "Acme", time_zone: "Europe/Paris") }
  let(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }
  let(:admin) { user_class.new(acme, [ :admin ]) }
  let(:support) { user_class.new(acme, [ :support ]) }

  def customer(account, name, city = "Paris") = account.customers.create!(name: name, email: "#{name}@example.test", city: city)

  def order(account, who, status: :paid, total: 1000, ordered_at: Time.current, ship_on: nil)
    account.orders.create!(customer: who, status: status, total_cents: total, ordered_at: ordered_at, ship_on: ship_on)
  end

  let!(:alice) { customer(acme, "Alice", "Paris") }
  let!(:bruno) { customer(acme, "Bruno", "Lyon") }
  let!(:other) { customer(globex, "Other", "Paris") }

  before do
    order(acme, alice, status: :paid, total: 1000)
    order(acme, alice, status: :shipped, total: 3000)
    order(acme, bruno, status: :paid, total: 500)
    order(globex, other, status: :paid, total: 999_999)
    order(globex, other, status: :paid, total: 999_999)
    order(globex, other, status: :paid, total: 999_999)
    order(globex, other, status: :paid, total: 999_999)
  end

  def answer(dataset = "orders", metric = "count", **rest)
    { "version" => 1, "intent" => "answer", "dataset" => dataset, "metric" => metric }.merge(rest.transform_keys(&:to_s))
  end

  def run_query(query, user = admin, **options) = described_class.call(query, user: user, **options)
  def value_of(query, user = admin) = run_query(query, user).result.value
  def rows_of(query, user = admin) = run_query(query, user).result.rows
  def filter(dimension, op, value = :none) = { "dimension" => dimension, "op" => op }.tap { |f| f["value"] = value unless value == :none }
  def by(dimension, granularity = nil) = { "dimension" => dimension, "granularity" => granularity }.compact

  def sql_of
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload unless payload[:name] == "SCHEMA" }
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "tenant isolation" do
    it "counts only the tenant's rows" do
      expect(value_of(answer)).to eq(3)
      expect(value_of(answer, user_class.new(globex, [ :admin ]))).to eq(4)
    end

    it "sums only the tenant's rows" do
      expect(value_of(answer("orders", "revenue"))).to eq(4500)
    end

    it "keeps the tenant's rows when the same filter matches both" do
      expect(value_of(answer(filters: [ filter("customer.city", "eq", "Paris") ]))).to eq(2)
    end

    it "applies to the dataset's own table on every metric" do
      expect(value_of(answer("orders", "customers"))).to eq(2)
      expect(value_of(answer("customers"))).to eq(2)
    end

    # A corrupt row must not bring another tenant's data out.
    it "filters each joined table too: an order pointing at another tenant's customer does not reveal it" do
      order(acme, other, total: 1)

      expect(rows_of(answer(group_by: [ by("customer.name") ])).map(&:first)).to contain_exactly("Alice", "Bruno")
      expect(value_of(answer(filters: [ filter("customer.name", "contains", "Other") ]))).to eq(0)
    end

    it "uses a sub-query for a longer path, and filters at each level" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Shipment", roles: %i[admin], tenant_path: %i[order account],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ]))
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      Order.where(account: acme).first.shipments.create!(carrier: "DHL")
      Order.where(account: globex).first.shipments.create!(carrier: "DHL")
      Order.where(account: globex).last.shipments.create!(carrier: "DHL")

      plan = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current).call(answer("shipments"))

      expect(plan.execute.value).to eq(1)
      expect(plan.to_sql).to match(/"shipments"\."order_id" IN \(SELECT "orders"\."id" FROM "orders" WHERE "orders"\."account_id" = #{acme.id}\)/)
    end

    it "joins and filters at each level of a depth 2 path" do
      datasets = [
        DataTeller::Dataset.new(model_name: "LineItem", roles: %i[admin], tenant_path: %i[order account],
                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ]),
        DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account], dimensions: [ DataTeller::Dimension.new(name: :status) ]),
        DataTeller::Dataset.new(model_name: "Customer", roles: %i[admin], tenant_path: %i[account], dimensions: [ DataTeller::Dimension.new(name: :city) ])
      ]
      registry = DataTeller::Registry.new
      datasets.each { |dataset| registry.register(dataset) }
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      product = acme.products.create!(name: "Hat", category: "Hats", price_cents: 100)
      foreign = globex.products.create!(name: "Hat", category: "Hats", price_cents: 100)
      Order.where(account: acme).find_each { |one| one.line_items.create!(product: product, quantity: 1, unit_price_cents: 1) }
      Order.where(account: globex).find_each { |one| one.line_items.create!(product: foreign, quantity: 1, unit_price_cents: 1) }

      plan = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)
                                 .call(answer("line_items", filters: [ filter("order.customer.city", "eq", "Paris"), filter("order.status", "eq", "paid") ]))

      expect(plan.execute.value).to eq(1)
      expect(plan.to_sql).to include(%("customers"."account_id" = #{acme.id}), %("orders"."account_id" = #{acme.id}))
    end

    # The boot refuses this. If it ever got this far, comparing ids across tables would return another tenant's rows.
    it "refuses a dataset with no path that is not the tenant model" do
      scope = DataTeller::TenantScope.new(acme)

      expect { scope.condition_for(Order, nil) }.to raise_error(DataTeller::Compiler::Refused, /no tenant_path/)
      expect { scope.condition_for(Order, %i[nope]) }.to raise_error(DataTeller::Compiler::Refused, /not a belongs_to/)

      stub_const("SpecNote", Class.new(ApplicationRecord) { self.table_name = "orders" })
      SpecNote.belongs_to :subject, polymorphic: true
      SpecNote.belongs_to :customer_subject, class_name: "Customer", foreign_key: :subject_id
      expect { scope.condition_for(SpecNote, %i[customer_subject account]) }
        .to raise_error(DataTeller::Compiler::Refused, /reads a polymorphic key without its type/)
    end

    it "filters a dataset on the tenant model by its own id" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Account", roles: %i[admin],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      plan = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current).call(answer("accounts"))

      expect(plan.execute.value).to eq(1)
    end

    it "filters a metric path's table too" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                metrics: [ DataTeller::Metric.new(name: :items, aggregation: :sum, column: "line_items.quantity") ]))
      registry.register(DataTeller::Dataset.new(model_name: "LineItem", roles: %i[admin], tenant_path: %i[order account]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      product = acme.products.create!(name: "Hat", category: "Hats", price_cents: 100)
      foreign = globex.products.create!(name: "Hat", category: "Hats", price_cents: 100)
      acme.orders.first.line_items.create!(product: product, quantity: 2, unit_price_cents: 100)
      globex.orders.first.line_items.create!(product: foreign, quantity: 50, unit_price_cents: 100)

      plan = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current).call(answer("orders", "items"))

      expect(plan.execute.value).to eq(2)
      expect(plan.to_sql).to include('"line_items"."order_id" IN (SELECT "orders"."id"')
    end

    it "refuses a user with no tenant, before anything runs" do
      statements = sql_of { expect(run_query(answer, user_class.new(nil, [ :admin ])).refusal.reason).to eq(:no_tenant) }

      expect(statements.map { |s| s[:sql] }.grep(/orders/)).to be_empty
    end

    it "refuses when the resolver returns another record" do
      expect(run_query(answer, user_class.new(alice, [ :admin ])).refusal.reason).to eq(:no_tenant)
    end
  end

  describe "the structural check" do
    it "refuses to run when a filter is missing from the final relation" do
      scope = DataTeller::TenantScope.new(acme)
      node = scope.condition_for(Order, %i[account])

      expect(scope.present_in?(Order.where(node), [ node ])).to be(true)
      expect(scope.present_in?(Order.where(status: 1).where(node), [ node ])).to be(true)
      expect(scope.present_in?(Order.where(status: 1), [ node ])).to be(false)
      expect(scope.present_in?(Order.all, [ node ])).to be(false)
      expect(scope.present_in?(Order.where(node).unscope(:where), [ node ])).to be(false)
    end
  end

  describe "the tenant at the end of a path" do
    let(:scope) { DataTeller::TenantScope.new(alice) }

    # Comparing a customer id to account_id would read the account that happens to have this id.
    it "must be an instance of the association's class" do
      expect { scope.condition_for(Order, %i[account]) }.to raise_error(DataTeller::Compiler::Refused, /ends at Account, the tenant is a Customer/)
    end

    it "must be reached through belongs_to only" do
      expect { DataTeller::TenantScope.new(acme).condition_for(Account, %i[orders]) }.to raise_error(DataTeller::Compiler::Refused, /not a belongs_to/)
    end
  end

  describe "bound parameters" do
    payload = "'; DROP TABLE orders; --"

    {
      "eq" => [ "customer.city", "eq", payload ],
      "not_eq" => [ "customer.city", "not_eq", payload ],
      "contains" => [ "customer.city", "contains", payload ],
      "in" => [ "customer.city", "in", [ payload ] ],
      "not_in" => [ "customer.city", "not_in", [ payload ] ]
    }.each do |label, (dimension, op, value)|
      it "never puts a value in the SQL, with #{label}" do
        statements = sql_of { run_query(answer(filters: [ filter(dimension, op, value) ])) }
        query = statements.find { |s| s[:sql].include?(%(FROM "orders")) }

        expect(query[:sql]).not_to include("DROP TABLE")
        expect(query[:sql]).to match(/\$\d/)
      end
    end

    it "binds the tenant id" do
      statements = sql_of { run_query(answer) }
      query = statements.find { |s| s[:sql].include?(%(FROM "orders")) }

      expect(query[:sql]).to match(/"orders"\."account_id" = \$\d/)
      expect(query[:sql]).not_to match(/"account_id" = #{acme.id}\b/)
    end

    it "escapes LIKE wildcards: a percent sign means a percent sign" do
      expect(value_of(answer(filters: [ filter("customer.city", "contains", "%") ]))).to eq(0)
      expect(value_of(answer(filters: [ filter("customer.city", "contains", "_aris") ]))).to eq(0)
      expect(value_of(answer(filters: [ filter("customer.city", "contains", "ari") ]))).to eq(2)
    end

    it "is case-insensitive on contains" do
      expect(value_of(answer(filters: [ filter("customer.city", "contains", "PARIS") ]))).to eq(2)
    end
  end

  describe "scope segments" do
    def compile_with(*scopes)
      segments = scopes.each_with_index.map { |scope, index| DataTeller::Segment.new(name: :"s#{index}", scope: scope, roles: :admin) }
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "SpecHostile", roles: %i[admin], tenant_path: %i[account], segments: segments,
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      filters = segments.map { |segment| { "segment" => segment.name.to_s } }
      DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)
                          .call(answer("spec_hostiles", filters: filters))
    end

    it "apply their conditions" do
      expect(compile_with(:paid_ones).execute.value).to eq(2)
    end

    # ADR 0001 D3: filters are AND-only, and merge would replace the first condition.
    it "combine with AND, in either order" do
      expect(compile_with(:paid_ones, :shipped_ones).execute.value).to eq(0)
      expect(compile_with(:shipped_ones, :paid_ones).execute.value).to eq(0)
    end
  end

  describe "a default_scope with an order" do
    it "still aggregates, and groups" do
      model = Class.new(ApplicationRecord)
      stub_const("SpecOrdered", model)
      model.class_eval do
        self.table_name = "orders"
        belongs_to :account
        default_scope { order(:ordered_at) }
      end
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "SpecOrdered", roles: %i[admin], tenant_path: %i[account],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                dimensions: [ DataTeller::Dimension.new(name: :status, group: true) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      compile = ->(query) { DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current).call(query) }

      expect(compile.call(answer("spec_ordereds")).execute.value).to eq(3)
      expect(compile.call(answer("spec_ordereds", group_by: [ by("status") ])).execute.rows.size).to eq(2)
    end
  end

  describe "a top N" do
    # Postgres sorts NULL first on DESC: a group with no value would take a slot from a real one.
    it "keeps groups with no value last" do
      metrics = [ DataTeller::Metric.new(name: :count, aggregation: :count), DataTeller::Metric.new(name: :total, aggregation: :sum, column: :total_cents),
                  DataTeller::Metric.new(name: :ratio, aggregation: :ratio, of: %i[total total]) ]
      order(acme, customer(acme, "Zero"), total: 0)
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account], metrics: metrics))
      registry.register(DataTeller::Dataset.new(model_name: "Customer", roles: %i[admin], tenant_path: %i[account],
                                                dimensions: [ DataTeller::Dimension.new(name: :name, group: true, max_groups: 2) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")

      rows = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)
                                 .call(answer("orders", "ratio", group_by: [ by("customer.name") ])).execute.rows

      expect(rows.map(&:first)).to eq(%w[Alice Bruno])
    end
  end

  it "does not carry a grouping over when a compiler is reused" do
    compiler = DataTeller::Compiler.new(catalog: DataTeller::Catalog.for(:admin), tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)

    expect(compiler.call(answer(group_by: [ by("status") ])).execute.columns).to eq(%w[status count])
    expect(compiler.call(answer(group_by: [ by("customer.name") ])).execute.rows.map(&:first)).to contain_exactly("Alice", "Bruno")
    expect(compiler.call(answer).execute.value).to eq(3)
  end

  it "refuses a date grouping when timestamps are not stored in UTC, rather than shift every group" do
    allow(ActiveRecord).to receive(:default_timezone).and_return(:local)

    expect(run_query(answer(group_by: [ by("ordered_at", "month") ])).refusal.reason).to eq(:unsupported_query)
  end

  it "refuses a date grouping on a column that does not exist" do
    registry = DataTeller::Registry.new
    registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                              metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                              dimensions: [ DataTeller::Dimension.new(name: :nope, type: :date) ]))
    catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
    compiler = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)

    expect { compiler.call(answer(group_by: [ by("nope", "month") ])) }.to raise_error(DataTeller::Compiler::Refused)
  end

  it "does not need the time zone for a plain count" do
    acme.update_column(:time_zone, "Mars/Olympus")

    expect(value_of(answer)).to eq(3)
  end

  describe "metrics" do
    it "computes every aggregation" do
      expect(value_of(answer("orders", "avg_basket"))).to eq(1500)
      expect(value_of(answer("orders", "customers"))).to eq(2)
    end

    it "returns 0 for a sum over nothing, and nil for a ratio over nothing" do
      none = [ filter("status", "eq", "cancelled") ]

      expect(value_of(answer("orders", "revenue", filters: none))).to eq(0)
      expect(value_of(answer("orders", "count", filters: none))).to eq(0)
      expect(value_of(answer("orders", "avg_basket", filters: none))).to be_nil
    end
  end

  describe "a ratio dividing by zero" do
    it "has no value, instead of an SQL error" do
      order(acme, alice, status: :cancelled, total: 0)
      metrics = [ DataTeller::Metric.new(name: :count, aggregation: :count), DataTeller::Metric.new(name: :total, aggregation: :sum, column: :total_cents),
                  DataTeller::Metric.new(name: :orders_per_cent, aggregation: :ratio, of: %i[count total]) ]
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account], metrics: metrics,
                                                dimensions: [ DataTeller::Dimension.new(name: :status) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      plan = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)
                                 .call(answer("orders", "orders_per_cent", filters: [ filter("status", "eq", "cancelled") ]))

      expect(plan.execute.value).to be_nil
    end
  end

  describe "filters" do
    it "applies enums by their name" do
      expect(value_of(answer(filters: [ filter("status", "eq", "paid") ]))).to eq(2)
      expect(value_of(answer(filters: [ filter("status", "in", %w[paid shipped]) ]))).to eq(3)
      expect(value_of(answer(filters: [ filter("status", "not_eq", "paid") ]))).to eq(1)
      expect(value_of(answer(filters: [ filter("status", "not_in", %w[paid]) ]))).to eq(1)
    end

    it "applies is_null" do
      alice.update!(city: nil)

      expect(value_of(answer(filters: [ filter("customer.city", "is_null") ]))).to eq(2)
      expect(value_of(answer(filters: [ filter("customer.city", "is_not_null") ]))).to eq(1)
    end

    it "applies segments, and combines everything with AND" do
      expect(value_of(answer(filters: [ { "segment" => "paid" } ]))).to eq(2)
      expect(value_of(answer(filters: [ { "segment" => "open" }, filter("customer.city", "eq", "Lyon") ]))).to eq(1)
    end

    it "keeps a filter and a segment on the same column as two conditions" do
      expect(value_of(answer(filters: [ { "segment" => "paid" }, filter("status", "eq", "shipped") ]))).to eq(0)
    end

    it "applies numeric comparisons" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                dimensions: [ DataTeller::Dimension.new(name: :total_cents) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      compile = lambda do |op, value|
        DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)
                            .call(answer(filters: [ filter("total_cents", op, value) ])).execute.value
      end

      expect(compile.call("gte", 1000)).to eq(2)
      expect(compile.call("gt", 1000)).to eq(1)
      expect(compile.call("lt", 1000)).to eq(1)
      expect(compile.call("lte", 1000)).to eq(2)
    end
  end

  describe "period" do
    def on(range, dimension = "ship_on") = answer(period: { "dimension" => dimension, "range" => range })

    it "filters a date column" do
      order(acme, alice, ship_on: Date.new(2026, 11, 6))
      order(acme, alice, ship_on: Date.new(2026, 11, 7))

      expect(value_of(on({ "on" => "2026-11-06" }))).to eq(1)
      expect(value_of(on({ "between" => { "from" => "2026-11-06", "to" => "2026-11-07" } }))).to eq(2)
    end

    # The whole point of T26: at 23:30 UTC it is already tomorrow in Paris.
    it "resolves tomorrow in the tenant's time zone" do
      travel_to(Time.utc(2026, 11, 4, 23, 30))
      order(acme, alice, ship_on: Date.new(2026, 11, 5))
      order(acme, alice, ship_on: Date.new(2026, 11, 6))
      order(globex, other, ship_on: Date.new(2026, 11, 5))

      expect(value_of(on({ "relative" => "today" }))).to eq(1) # Acme, in Paris: already the 5th
      expect(value_of(on({ "relative" => "tomorrow" }))).to eq(1) # the 6th in Paris
      expect(value_of(on({ "relative" => "tomorrow" }), user_class.new(globex, [ :admin ]))).to eq(1) # Globex, in UTC: still the 4th
    end

    it "uses the day boundaries of the tenant's time zone on a datetime column" do
      order(acme, alice, ordered_at: Time.utc(2026, 11, 2, 23, 30), total: 1) # already Nov 3 in Paris
      order(acme, alice, ordered_at: Time.utc(2026, 11, 3, 22, 30), total: 2) # still Nov 3 in Paris
      order(acme, alice, ordered_at: Time.utc(2026, 11, 3, 23, 30), total: 4) # Nov 4 in Paris, Nov 3 in UTC

      # Distinct totals, because a count of 2 would also be the right answer with the wrong time zone.
      expect(value_of(answer("orders", "revenue", period: { "dimension" => "ordered_at", "range" => { "on" => "2026-11-03" } }))).to eq(3)
    end
  end

  describe "group_by" do
    it "returns one row per group, enums by their name" do
      result = run_query(answer("orders", "revenue", group_by: [ by("status") ])).result

      expect(result.columns).to eq(%w[status revenue])
      expect(result.rows).to contain_exactly([ "paid", 1500 ], [ "shipped", 3000 ])
      expect(result.truncated).to be(false)
    end

    it "groups by a path" do
      expect(rows_of(answer("orders", "revenue", group_by: [ by("customer.name") ]))).to eq([ [ "Alice", 4000 ], [ "Bruno", 500 ] ])
    end

    it "groups by two dimensions" do
      expect(rows_of(answer(group_by: [ by("status"), by("customer.name") ])))
        .to contain_exactly([ "paid", "Alice", 1 ], [ "shipped", "Alice", 1 ], [ "paid", "Bruno", 1 ])
    end

    it "truncates dates in the tenant's time zone" do
      order(acme, alice, ordered_at: Time.utc(2026, 9, 30, 22, 30), total: 7) # already October in Paris

      rows = rows_of(answer("orders", "count", group_by: [ by("ordered_at", "month") ], filters: [ filter("customer.city", "eq", "Paris") ]))

      expect(rows.first.first).to eq(Date.new(2026, 10, 1))
    end

    it "orders dates chronologically by default" do
      order(acme, alice, ordered_at: Time.utc(2026, 1, 15))

      dates = rows_of(answer(group_by: [ by("ordered_at", "month") ])).map(&:first)

      expect(dates).to eq(dates.sort)
    end
  end

  describe "order_by and limit" do
    it "orders by the metric" do
      expect(rows_of(answer("orders", "revenue", group_by: [ by("status") ], order_by: { "by" => "metric", "dir" => "asc" })).map(&:first)).to eq(%w[paid shipped])
      expect(rows_of(answer("orders", "revenue", group_by: [ by("status") ], order_by: { "by" => "metric", "dir" => "desc" })).map(&:first)).to eq(%w[shipped paid])
    end

    it "orders by a dimension" do
      expect(rows_of(answer(group_by: [ by("customer.name") ], order_by: { "by" => "dimension", "dimension" => "customer.name", "dir" => "desc" })).map(&:first))
        .to eq(%w[Bruno Alice])
    end

    it "marks a limited result as truncated when there was more" do
      result = run_query(answer("orders", "revenue", group_by: [ by("customer.name") ], order_by: { "by" => "metric", "dir" => "desc" }, limit: 1)).result

      expect(result.rows).to eq([ [ "Alice", 4000 ] ])
      expect(result.truncated).to be(true)
    end

    it "does not mark it when everything fits" do
      expect(run_query(answer(group_by: [ by("customer.name") ], limit: 2)).result.truncated).to be(false)
    end
  end

  # ADR 0004 D3: "revenue per customer" is a normal question, not a refusal.
  describe "a high-cardinality grouping with no order or limit" do
    before do
      25.times { |i| order(acme, customer(acme, format("C%02d", i)), total: 100 + i) }
    end

    it "gets the top max_groups by the metric, marked as truncated" do
      result = run_query(answer("orders", "revenue", group_by: [ by("customer.name") ])).result

      expect(result.rows.size).to eq(20) # max_groups in the dummy's customers.rb
      expect(result.rows.first).to eq([ "Alice", 4000 ])
      expect(result.truncated).to be(true)
    end

    it "keeps a smaller limit" do
      expect(run_query(answer("orders", "revenue", group_by: [ by("customer.name") ], limit: 3)).result.rows.size).to eq(3)
    end

    it "does not let a bigger limit go past max_groups" do
      expect(run_query(answer("orders", "revenue", group_by: [ by("customer.name") ], limit: 50)).result.rows.size).to eq(20)
    end
  end

  describe "execution guards" do
    # The published config is frozen: a variant built the same way a file would, with the settings of the example.
    def with_settings(**settings)
      config = DataTeller::Loader.capture do
        DataTeller.configure do |c|
          c.tenant do
            model Account
            resolve { |user| user.account }
            time_zone(&:time_zone)
          end
          c.roles { |user| user.roles }
          settings.each { |name, value| c.public_send("#{name}=", value) }
        end
      end.config
      allow(DataTeller).to receive(:config).and_return(config)
    end

    describe "read-only" do
      before(:all) do
        Object.const_set(:SpecWriter, Class.new(ApplicationRecord))
        SpecWriter.class_eval do
          self.table_name = "orders"
          belongs_to :account

          scope :writes_when_called, -> { update_all(total_cents: 0) && where(status: 1) }
        end
      end

      after(:all) { Object.send(:remove_const, :SpecWriter) }

      # Calling a scope runs its code, at compile time: compilation has to be guarded too, not only the final query.
      it "covers the compilation, where scopes are called" do
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "SpecWriter", roles: %i[admin], tenant_path: %i[account],
                                                  metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                  segments: [ DataTeller::Segment.new(name: :x, scope: :writes_when_called, roles: :admin) ]))
        catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
        allow(DataTeller::Catalog).to receive(:for_user).and_return(catalog)

        outcome = run_query(answer("spec_writers", filters: [ { "segment" => "x" } ]))

        expect(outcome.refusal.reason).to eq(:unsupported_query)
        expect(Order.where(account: acme).sum(:total_cents)).to eq(4500)
      end

      it "runs the query in a read-only transaction" do
        statements = sql_of { run_query(answer) }.map { |s| s[:sql] }

        expect(statements).to include("SET TRANSACTION READ ONLY")
        expect(statements.index("SET TRANSACTION READ ONLY")).to be < statements.index { |sql| sql.include?(%(FROM "orders")) }
      end
    end

    describe "statement timeout" do
      it "uses the configured value" do
        with_settings(query_timeout: 2)

        expect(sql_of { run_query(answer) }.map { |s| s[:sql] }).to include("SET LOCAL statement_timeout = 2000")
      end

      # Two statements each well under the timeout, together over it (ADR 0013 D2): a compare, or a count of hidden groups.
      it "is a budget for the whole question, not for each statement" do
        with_settings(query_timeout: 0.3)
        allow_any_instance_of(DataTeller::Plan).to receive(:execute).and_wrap_original do |original|
          2.times.map do
            sleep 0.2
            original.receiver.raw_rows
          end
        end
        allow(Rails.logger).to receive(:error)

        expect(run_query(answer).refusal.reason).to eq(:query_timeout)
      end

      it "gives a dedicated refusal, and the host's transaction goes on" do
        with_settings(query_timeout: 0.05)
        allow_any_instance_of(DataTeller::Plan).to receive(:execute) { Order.with_connection { |c| c.execute("SELECT pg_sleep(2)") } }
        allow(Rails.logger).to receive(:error)

        expect(run_query(answer).refusal.reason).to eq(:query_timeout)
        expect { alice.update!(city: "Nice") }.not_to raise_error
      end
    end

    # Each path alone is fine. Together Rails aliases the second join, and the sum and the tenant filter read the first one.
    describe "two paths to one table in a query" do
      let(:catalog_models) do
        order_model = Class.new(ApplicationRecord) do
          self.table_name = "orders"
          belongs_to :account
          belongs_to :featured_product, class_name: "Product", foreign_key: :customer_id
          has_many :line_items, foreign_key: :order_id
        end
        stub_const("SpecTwoPaths", order_model)
      end

      def two_paths_catalog
        catalog_models
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "SpecTwoPaths", roles: %i[admin], tenant_path: %i[account],
                                                  metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count),
                                                             DataTeller::Metric.new(name: :catalog_value, aggregation: :sum, column: "line_items.product.price_cents") ]))
        registry.register(DataTeller::Dataset.new(model_name: "LineItem", roles: %i[admin], tenant_path: %i[order account],
                                                  dimensions: [ DataTeller::Dimension.new(name: :quantity) ]))
        registry.register(DataTeller::Dataset.new(model_name: "Product", roles: %i[admin], tenant_path: %i[account],
                                                  dimensions: [ DataTeller::Dimension.new(name: :name, group: true) ]))
        DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      end

      def compiled(query)
        DataTeller::Compiler.new(catalog: two_paths_catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)
                            .call({ "version" => 1, "intent" => "answer", "dataset" => "spec_two_paths" }.merge(query))
      end

      it "is refused" do
        expect { compiled("metric" => "catalog_value", "group_by" => [ { "dimension" => "featured_product.name" } ]) }
          .to raise_error(DataTeller::Compiler::Refused, /two paths/)
      end

      it "lets each path through alone" do
        expect(compiled("metric" => "catalog_value").to_sql).to include("line_items")
        expect(compiled("metric" => "count", "group_by" => [ { "dimension" => "featured_product.name" } ]).to_sql).to include("products")
      end
    end

    describe "time series (ADR 0004 D3)" do
      before do
        with_settings(max_time_points: 2)
        3.times { |i| order(acme, alice, ordered_at: Time.utc(2026, 1 + i, 15)) }
      end

      def by_month(**rest) = answer(group_by: [ by("ordered_at", "month") ], **rest)

      # A top N of days means nothing: the user has to ask for a wider granularity.
      it "are refused with too_many_groups beyond the cap, not truncated" do
        expect(run_query(by_month).refusal.reason).to eq(:too_many_groups)
      end

      it "are answered when the period keeps them under the cap" do
        period = { "dimension" => "ordered_at", "range" => { "between" => { "from" => "2026-01-01", "to" => "2026-02-28" } } }

        expect(run_query(by_month(period: period)).result.rows.size).to eq(2)
      end

      it "are answered with an explicit top N, which the user asked for" do
        result = run_query(by_month(order_by: { "by" => "metric", "dir" => "desc" }, limit: 2)).result

        expect(result.rows.size).to eq(2)
        expect(result.truncated).to be(true)
      end

      # Two months, four rows: what is limited is the number of dates, not of rows.
      it "count the dates, not the rows" do
        order(acme, alice, status: :pending, ordered_at: Time.utc(2026, 1, 16))
        order(acme, alice, status: :pending, ordered_at: Time.utc(2026, 2, 16))
        period = { "dimension" => "ordered_at", "range" => { "between" => { "from" => "2026-01-01", "to" => "2026-02-28" } } }

        rows = run_query(answer(group_by: [ by("status"), by("ordered_at", "month") ], period: period)).result.rows
        expect(rows.size).to eq(4)
        expect(rows.map(&:last).sum).to eq(4)
      end

      it "are refused beyond the cap on dates whatever the other groups" do
        expect(run_query(answer(group_by: [ by("status"), by("ordered_at", "month") ])).refusal.reason).to eq(:too_many_groups)
      end

      it "stay under max_rows, refused and not cut" do
        with_settings(max_time_points: 100, max_rows: 2)

        expect(run_query(by_month).refusal.reason).to eq(:too_many_groups)
      end

      it "do not apply when a high-cardinality dimension already caps the query" do
        expect(run_query(answer(group_by: [ by("customer.name"), by("ordered_at", "month") ])).status).to eq(:answered)
      end
    end

    describe "row and group caps" do
      it "uses max_rows on any grouped query" do
        with_settings(max_rows: 1)

        result = run_query(answer(group_by: [ by("status") ])).result

        expect(result.rows.size).to eq(1)
        expect(result.truncated).to be(true)
      end

      it "uses default_max_groups when a dimension has no max_groups" do
        with_settings(default_max_groups: 1)
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                  metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                  dimensions: [ DataTeller::Dimension.new(name: :customer_id, group: true) ]))
        catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
        allow(DataTeller::Catalog).to receive(:for_user).and_return(catalog)

        expect(run_query(answer(group_by: [ by("customer_id") ])).result.rows.size).to eq(1)
      end
    end

    describe "join cap (ADR 0001 D4)" do
      it "refuses a query joining too many tables" do
        with_settings(max_joins: 0)

        expect(run_query(answer(filters: [ filter("customer.city", "eq", "Paris") ])).refusal.reason).to eq(:unsupported_query)
      end

      it "accepts one under the cap" do
        with_settings(max_joins: 1)

        expect(run_query(answer(filters: [ filter("customer.city", "eq", "Paris") ])).status).to eq(:answered)
      end
    end
  end

  describe "compare" do
    # Now is 2026-11-04: last_month is October, and the period before it is September.
    def on_ordered(range = { "relative" => "last_month" }) = { "dimension" => "ordered_at", "range" => range }
    def compare_query(metric = "revenue", mode = "previous_period", **rest)
      answer("orders", metric, period: on_ordered, compare: mode, **rest)
    end

    before do
      order(acme, alice, status: :paid, total: 100, ordered_at: Time.utc(2026, 10, 10))
      order(acme, bruno, status: :shipped, total: 200, ordered_at: Time.utc(2026, 10, 20))
      order(acme, alice, status: :paid, total: 50, ordered_at: Time.utc(2026, 9, 10))
      order(acme, alice, status: :paid, total: 7, ordered_at: Time.utc(2025, 10, 10))
    end

    it "gives both values, and the two periods" do
      result = run_query(compare_query).result

      expect(result.value).to eq(300)
      expect(result.previous_value).to eq(50)
      expect(result.columns).to eq(%w[revenue previous_revenue])
      expect(result.period).to eq([ Date.new(2026, 10, 1), Date.new(2026, 11, 1) ])
      expect(result.compared_period).to eq([ Date.new(2026, 9, 1), Date.new(2026, 10, 1) ])
    end

    it "compares to the same dates a year earlier" do
      expect(run_query(compare_query("revenue", "previous_year")).result.previous_value).to eq(7)
    end

    it "gives the period to a query without compare, with no comparison" do
      result = run_query(answer("orders", "revenue", period: on_ordered)).result

      expect(result.value).to eq(300)
      expect(result.period).to eq([ Date.new(2026, 10, 1), Date.new(2026, 11, 1) ])
      expect(result.compared_period).to be_nil
      expect(result.previous_value).to be_nil
    end

    # The second query is a query too: the leak would be easy to miss, in a number shown as a comparison.
    it "applies the tenant filter to both periods" do
      order(globex, other, total: 500_000, ordered_at: Time.utc(2026, 9, 10))

      expect(run_query(compare_query).result.previous_value).to eq(50)

      statements = sql_of { run_query(compare_query) }.map { |s| s[:sql] }.select { |sql| sql.include?(%(FROM "orders")) }
      expect(statements.size).to eq(2)
      expect(statements).to all(match(/"orders"\."account_id" = \$\d/))
    end

    it "runs both queries in the same read-only transaction" do
      statements = sql_of { run_query(compare_query) }.map { |s| s[:sql] }

      expect(statements.count("SET TRANSACTION READ ONLY")).to eq(1)
    end

    it "gives 0 for a sum and no value for a ratio when the previous period is empty" do
      query = answer("orders", "revenue", period: on_ordered({ "on" => "2026-10-10" }), compare: "previous_period")
      ratio = answer("orders", "avg_basket", period: on_ordered({ "on" => "2026-10-10" }), compare: "previous_period")

      expect(run_query(query).result.previous_value).to eq(0)
      expect(run_query(ratio).result.previous_value).to be_nil
    end

    describe "with a group_by" do
      it "lines each group up with its previous value, enums by their name" do
        result = run_query(compare_query(group_by: [ by("status") ])).result

        expect(result.columns).to eq(%w[status revenue previous_revenue])
        expect(result.rows).to contain_exactly([ "paid", 100, 50 ], [ "shipped", 200, 0 ])
      end

      it "gives 0 to a group that did not exist before" do
        rows = run_query(compare_query(group_by: [ by("customer.name") ])).result.rows

        expect(rows).to contain_exactly([ "Alice", 100, 50 ], [ "Bruno", 200, 0 ])
      end

      it "lines up two dimensions" do
        rows = run_query(compare_query(group_by: [ by("status"), by("customer.name") ])).result.rows

        expect(rows).to contain_exactly([ "paid", "Alice", 100, 50 ], [ "shipped", "Bruno", 200, 0 ])
      end

      # The previous value of a top group must not depend on where that group ranked back then.
      it "finds the previous value of a group that was not in the previous top N" do
        order(acme, bruno, status: :shipped, total: 1, ordered_at: Time.utc(2026, 9, 11))
        order(acme, alice, status: :paid, total: 5_000, ordered_at: Time.utc(2026, 9, 12))

        result = run_query(compare_query(group_by: [ by("customer.name") ], order_by: { "by" => "metric", "dir" => "desc" }, limit: 1)).result

        expect(result.rows).to eq([ [ "Bruno", 200, 1 ] ])
        expect(result.truncated).to be(true)
      end

      it "lines up a group with no value" do
        alice.update!(city: nil)
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account], dimensions: [ DataTeller::Dimension.new(name: :ordered_at, time: true) ],
                                                  metrics: [ DataTeller::Metric.new(name: :revenue, aggregation: :sum, column: :total_cents) ]))
        registry.register(DataTeller::Dataset.new(model_name: "Customer", roles: %i[admin], tenant_path: %i[account], dimensions: [ DataTeller::Dimension.new(name: :city, group: true) ]))
        catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
        plan = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)
                                   .call(compare_query(group_by: [ by("customer.city") ]))

        expect(plan.execute.rows).to contain_exactly([ nil, 100, 50 ], [ "Lyon", 200, 0 ])
      end

      it "binds the group values of the second query" do
        statements = sql_of { run_query(compare_query(group_by: [ by("customer.name") ])) }.map { |s| s[:sql] }.select { |sql| sql.include?(%(FROM "orders")) }

        expect(statements.last).to match(/"customers"\."name" IN \(\$\d/)
        expect(statements.last).not_to include("Alice")
      end
    end

    it "refuses a date group" do
      expect(run_query(compare_query(group_by: [ by("ordered_at", "month") ])).refusal.reason).to eq(:unsupported_query)
    end
  end

  describe "refusals" do
    it "refuses what the validator refuses, without running anything" do
      statements = sql_of { expect(run_query(answer("quotes")).refusal.reason).to eq(:unknown_dataset) }

      expect(statements.map { |s| s[:sql] }.grep(/invoices/)).to be_empty
    end

    it "hides a metric from a role, with the same refusal as an unknown one" do
      expect(run_query(answer("orders", "revenue"), support).refusal.reason).to eq(:unknown_metric)
      expect(run_query(answer("orders", "margin"), support).refusal.reason).to eq(:unknown_metric)
    end

    it "refuses everything without a role" do
      expect(run_query(answer, user_class.new(acme, [])).refusal.reason).to eq(:unknown_dataset)
    end

    it "refuses when the engine is off" do
      DataTeller.reset!

      expect(run_query(answer).refusal.reason).to eq(:engine_disabled)
    ensure
      DataTeller.boot!(Rails.root)
    end

    # Not implemented yet: a refusal, never an approximation (ADR 0005).
    it "refuses a lookup until it exists" do
      query = answer(filters: [ filter("customer.name", "eq", { "lookup" => "Dupont" }) ])

      expect(run_query(query).refusal.reason).to eq(:unsupported_query)
    end

    it "refuses a relative condition in a segment until its syntax is decided" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                segments: [ DataTeller::Segment.new(name: :old, where: { created_before: { days_ago: 30 } }) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      compiler = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)

      expect { compiler.call(answer(filters: [ { "segment" => "old" } ])) }.to raise_error(DataTeller::Compiler::Refused)
    end

    it "refuses when the tenant's time zone is invalid, rather than using the wrong day" do
      acme.update_column(:time_zone, "Mars/Olympus")
      allow(Rails.logger).to receive(:error)

      query = answer(period: { "dimension" => "ship_on", "range" => { "relative" => "today" } })

      expect(run_query(query).refusal.reason).to eq(:unsupported_query)
    end

    # ADR 0004 D6: the boot does not read the database, so a column can be missing here.
    it "refuses when a column is missing, without giving the database's message to anyone" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                dimensions: [ DataTeller::Dimension.new(name: :nope) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      allow(DataTeller::Catalog).to receive(:for_user).and_return(catalog)
      allow(Rails.logger).to receive(:error)

      outcome = run_query(answer(filters: [ filter("nope", "eq", "x") ]))

      expect(outcome.refusal.reason).to eq(:unsupported_query)
      expect(Rails.logger).to have_received(:error).with(/ActiveRecord::StatementInvalid/)
      expect(Rails.logger).not_to have_received(:error).with(/nope/)
    end

    it "does not let the compiler run an invalid query, even when called directly" do
      compiler = DataTeller::Compiler.new(catalog: DataTeller::Catalog.for(:admin), tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)

      expect { compiler.call(answer("quotes")) }.to raise_error(DataTeller::Compiler::Refused)
    end
  end

  describe "other intents" do
    it "passes clarify through, untouched" do
      query = { "version" => 1, "intent" => "clarify", "clarify" => { "reason" => "ambiguous_metric", "options" => %w[count revenue] } }
      outcome = run_query(query)

      expect(outcome.status).to eq(:clarify)
      expect(outcome.query).to eq(query)
    end

    it "passes out_of_scope through, untouched" do
      query = { "version" => 1, "intent" => "out_of_scope", "out_of_scope" => { "reason" => "not_a_data_question" } }

      expect(run_query(query).status).to eq(:out_of_scope)
    end
  end

  # For the developer, never for an end user (ADR 0005 D5).
  describe "trace" do
    def traced(query, user = admin, **options) = run_query(query, user, trace: true, **options).trace

    it "is off unless asked for" do
      expect(run_query(answer).trace).to be_nil
    end

    it "stops at access when nobody can be resolved" do
      expect(traced(answer, user_class.new(nil, [ :admin ]))).to have_attributes(stage: :access, problems: [], sql: [])
    end

    it "stops at validation, with the validator's codes and no SQL" do
      trace = traced(answer("orders", "revenue"), support)

      expect(trace.stage).to eq(:validation)
      expect(trace.problems).to eq([ { pointer: "/metric", code: :unknown_metric, reason: :unknown_metric } ])
      expect(trace.sql).to eq([])
    end

    # The refusal says unknown either way (ADR 0001 D5); the developer needs to know which.
    describe "names hidden from the role" do
      it "tells which roles see a refused metric" do
        expect(traced(answer("orders", "revenue"), support).hidden).to eq([ { pointer: "/metric", visible_to: [ :admin ] } ])
      end

      it "tells it for a dataset and for a dimension through a path" do
        member = user_class.new(acme, [ :member ])

        expect(traced(answer("customers"), member).hidden).to eq([ { pointer: "/dataset", visible_to: %i[admin support] } ])
        expect(traced(answer(group_by: [ by("customer.city") ]), member).hidden).to eq([ { pointer: "/group_by/0/dimension", visible_to: %i[admin support] } ])
      end

      it "says nothing of a name no role has" do
        expect(traced(answer("orders", "margin"), support).hidden).to eq([])
        expect(traced(answer(group_by: [ by("customer.email") ])).hidden).to eq([])
      end

      it "says nothing of a name the user sees but used wrongly" do
        trace = traced(answer(group_by: [ by("customer.city") ]))

        expect(trace.problems.map { |problem| problem[:code] }).to eq([ :not_groupable ])
        expect(trace.hidden).to eq([])
      end

      it "is not computed without the trace" do
        expect(DataTeller::HiddenNames).not_to receive(:new)

        run_query(answer("orders", "revenue"), support)
      end
    end

    it "stops at compilation when the compiler refuses" do
      allow(DataTeller::Compiler).to receive(:new).and_wrap_original do |original, **arguments|
        original.call(**arguments).tap { |compiler| allow(compiler).to receive(:call).and_raise(DataTeller::Compiler::Refused.new(:unsupported_query)) }
      end

      expect(traced(answer)).to have_attributes(stage: :compilation, sql: [])
    end

    it "stops at execution when the database cancels the query" do
      allow_any_instance_of(DataTeller::Plan).to receive(:execute).and_raise(ActiveRecord::QueryCanceled)
      allow(Rails.logger).to receive(:error)

      expect(traced(answer).stage).to eq(:execution)
    end

    it "goes through, with the SQL that ran and its tenant filter" do
      trace = traced(answer("orders", "revenue", group_by: [ by("customer.name") ]))

      expect(trace.stage).to be_nil
      expect(trace.sql.size).to eq(1)
      expect(trace.sql.first).to include(%("orders"."account_id" = #{acme.id}), %("customers"."account_id" = #{acme.id}))
    end

    it "holds both queries of a comparison, the second narrowed to the groups shown" do
      order(acme, alice, status: :paid, total: 100, ordered_at: Time.utc(2026, 10, 10))
      order(acme, alice, status: :paid, total: 50, ordered_at: Time.utc(2026, 9, 10))
      query = answer("orders", "revenue", group_by: [ by("customer.name") ], compare: "previous_period",
                                          period: { "dimension" => "ordered_at", "range" => { "relative" => "last_month" } })

      sql = traced(query, admin, now: Time.utc(2026, 11, 4)).sql

      expect(sql.size).to eq(2)
      expect(sql).to all(include(%("orders"."account_id" = #{acme.id})))
      expect(sql.last).to include(%("customers"."name" IN ('Alice')))
    end

    it "goes through a clarification without SQL" do
      query = { "version" => 1, "intent" => "clarify", "clarify" => { "reason" => "ambiguous_metric", "options" => %w[count revenue] } }

      expect(traced(query)).to have_attributes(stage: nil, problems: [], sql: [])
    end
  end
end
