require "rails_helper"

# Real rows on two tenants: the only proof of isolation that counts is what actually comes out of the database.
RSpec.describe DataTeller::QueryRunner do
  before(:all) do
    # Spec-only model: hostile scopes that the dummy app's clean domain does not have (ADR 0004 D4).
    Object.const_set(:SpecHostile, Class.new(ApplicationRecord))
    SpecHostile.class_eval do
      self.table_name = "orders"
      belongs_to :account

      scope :calls_unscoped, -> { unscoped }
      scope :unscopes_tenant, -> { unscope(where: :account_id) }
      scope :or_everything, -> { where(status: 1).or(where.not(status: 1)) }
      scope :rewhere_other, ->(id = Account.where(name: "Globex").pick(:id)) { rewhere(account_id: id) }
      scope :raw_or, -> { where("1=1 OR 1=1") }
      scope :from_subquery, -> { from("(SELECT * FROM orders) orders") }
      scope :fine, -> { where(status: 1) }
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
      expect { scope.condition_for(Order, %i[nope]) }.to raise_error(DataTeller::Compiler::Refused, /no association/)
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

    describe "with hostile scopes (ADR 0004 D4)" do
      def compile_with(scope, tenant = acme)
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "SpecHostile", roles: %i[admin], tenant_path: %i[account],
                                                  metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                  segments: [ DataTeller::Segment.new(name: :x, scope: scope, roles: :admin) ]))
        catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
        DataTeller::Compiler.new(catalog: catalog, tenant: tenant, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)
                            .call(answer("spec_hostiles", filters: [ { "segment" => "x" } ]))
      end

      {
        calls_unscoped: 3, unscopes_tenant: 3, or_everything: 3, raw_or: 3, from_subquery: 3,
        rewhere_other: 0, # both conditions apply, so nothing matches: still nothing from the other tenant
        fine: 2
      }.each do |scope, expected|
        it "#{scope} cannot escape the tenant" do
          expect(compile_with(scope).execute.value).to eq(expected)
        end
      end
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

  describe "refusals" do
    it "refuses what the validator refuses, without running anything" do
      statements = sql_of { expect(run_query(answer("invoices")).refusal.reason).to eq(:unknown_dataset) }

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
    it "refuses compare until it exists" do
      query = answer(period: { "dimension" => "ship_on", "range" => { "relative" => "today" } }, compare: "previous_period")

      expect(run_query(query).refusal.reason).to eq(:unsupported_query)
    end

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
      allow(DataTeller::Catalog).to receive(:new).and_return(catalog)
      allow(Rails.logger).to receive(:error)

      outcome = run_query(answer(filters: [ filter("nope", "eq", "x") ]))

      expect(outcome.refusal.reason).to eq(:unsupported_query)
      expect(Rails.logger).to have_received(:error).with(/ActiveRecord::StatementInvalid/)
      expect(Rails.logger).not_to have_received(:error).with(/nope/)
    end

    it "does not let the compiler run an invalid query, even when called directly" do
      compiler = DataTeller::Compiler.new(catalog: DataTeller::Catalog.for(:admin), tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current)

      expect { compiler.call(answer("invoices")) }.to raise_error(DataTeller::Compiler::Refused)
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
end
