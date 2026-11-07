require "rails_helper"

# Permanent regression tests, on real rows. Every attack vector runs against every query shape, and the invariant is always the
# same: another tenant's data never comes out. A green cell means refused, or answered with the tenant's rows only.
RSpec.describe "Tenant isolation matrix" do
  SENTINEL = 999_999 # Globex's total on each row: any trace of it in a result is a leak.
  OWN_TOTAL = 4_500

  # Each vector is a `scope:` a model could declare. `expected` is what must happen to it.
  # refuse: only conditions are accepted (ADR 0004 D4). narrow: it may run, the tenant filter still holds.
  SCOPE_VECTORS = {
    # Regression: this one returned 2001 instead of 1, with the structural check passing.
    from_redefining_the_tenant_column: [ :refuse, -> { from("(SELECT id, customer_id, total_cents, status, ship_on, ordered_at, #{Account.find_by!(name: "Acme").id} AS account_id FROM orders) orders") } ],
    from_select_all: [ :refuse, -> { from("(SELECT * FROM orders) orders") } ],
    cte_redefining_the_table: [ :refuse, -> { with(orders: Order.unscoped.select(:id, :customer_id, :total_cents, :status, :ship_on, :ordered_at, "#{Account.find_by!(name: "Acme").id} AS account_id")) } ],
    # Regression: this one returned 2001 too, the OR escaping the AND of the tenant filter.
    raw_sql_breaking_out_of_its_parentheses: [ :refuse, -> { where("1=1) OR (1=1") } ],
    raw_sql_with_a_comment: [ :refuse, -> { where("1=1) --") } ],
    raw_sql_always_true: [ :refuse, -> { where("1=1 OR 1=1") } ],
    raw_sql_harmless_looking: [ :refuse, -> { where("total_cents > 0") } ],
    arel_literal: [ :refuse, -> { where(Arel.sql("1=1) OR (1=1")) } ],
    or_with_raw_sql: [ :refuse, -> { where(status: 1).or(where("1=1")) } ],
    # Regressions from the third review: each of these got past a check that looked for what is dangerous.
    raw_in_an_attribute_name: [ :refuse, -> { where(arel_table[Arel.sql("id = id OR 1")].eq(1)) } ],
    raw_in_a_table_name: [ :refuse, -> { where(Arel::Table.new(Arel.sql("orders WHERE 1=1 OR 1"))[:id].eq(1)) } ],
    or_without_parentheses: [ :refuse, -> { where(Arel::Nodes::Or.new([ arel_table[:id].gt(0), arel_table[:id].lt(0) ])) } ],
    exists_reading_another_tenant: [ :refuse, -> { where(Order.unscoped.where(total_cents: SENTINEL).arel.exists) } ],
    in_a_sub_query: [ :refuse, -> { where(id: Order.unscoped.select(:id)) } ],
    raw_inside_a_sub_query: [ :refuse, -> { where(id: Order.unscoped.where("1=1)) OR ((1=1").select(:id)) } ],
    bound_raw_sql: [ :refuse, -> { where("1=1) OR (1=?", 1) } ],
    raw_next_to_an_and: [ :refuse, -> { where(arel_table[:status].eq(1).and(Arel.sql("1=1 OR 1=1"))) } ],
    sql_function: [ :refuse, -> { where(arel_table[:status].lower.eq("x")) } ],
    column_of_another_table: [ :refuse, -> { where(Customer.arel_table[:city].eq("Paris")) } ],
    an_alias_of_the_table: [ :refuse, -> { where(arel_table.alias("x")[:status].eq(1)) } ],
    a_literal_as_a_value: [ :refuse, -> { where(arel_table[:status].eq(Arel.sql("status OR 1=1"))) } ],
    none: [ :refuse, -> { none } ],
    unscope_where: [ :refuse, -> { unscope(where: :account_id) } ],
    joins_inner: [ :refuse, -> { joins(:customer) } ],
    joins_raw: [ :refuse, -> { joins("INNER JOIN customers c ON true") } ],
    left_joins: [ :refuse, -> { left_joins(:customer) } ],
    group: [ :refuse, -> { group(:customer_id) } ],
    having: [ :refuse, -> { group(:id).having("COUNT(*) > 0") } ],
    select: [ :refuse, -> { select(:id) } ],
    distinct: [ :refuse, -> { distinct } ],
    order: [ :refuse, -> { order(:id) } ],
    limit: [ :refuse, -> { limit(1) } ],
    offset: [ :refuse, -> { offset(1) } ],
    lock: [ :refuse, -> { lock } ],
    another_model: [ :refuse, -> { Customer.where(city: "Paris") } ],
    not_a_relation: [ :refuse, -> { 42 } ],
    writes_when_called: [ :refuse, -> { unscoped.update_all(total_cents: SENTINEL) && where(status: 1) } ],
    deletes_when_called: [ :refuse, -> { unscoped.delete_all && where(status: 1) } ],
    calls_unscoped: [ :narrow, -> { unscoped } ],
    unscoped_with_another_tenant: [ :narrow, -> { unscoped.where(account_id: Account.find_by!(name: "Globex").id) } ],
    rewhere_another_tenant: [ :refuse, -> { rewhere(account_id: Account.find_by!(name: "Globex").id) } ],
    where_another_tenant: [ :narrow, -> { where(account_id: Account.find_by!(name: "Globex").id) } ],
    or_everything: [ :narrow, -> { where(status: 1).or(where.not(status: 1)) } ],
    or_another_tenant: [ :narrow, -> { where(status: 1).or(where(account_id: Account.find_by!(name: "Globex").id)) } ],
    plain_condition: [ :narrow, -> { where(status: 1) } ],
    # What a segment is for: these must stay accepted, in every form Rails builds them.
    a_list: [ :narrow, -> { where(status: [ 1, 2 ]) } ],
    not_a_list: [ :narrow, -> { where.not(status: [ 3, 4 ]) } ],
    a_null: [ :narrow, -> { where(ship_on: nil) } ],
    a_list_with_a_null: [ :narrow, -> { where(ship_on: [ nil, Date.current ]) } ],
    a_range: [ :narrow, -> { where(total_cents: 0..SENTINEL) } ],
    an_open_range: [ :narrow, -> { where(total_cents: 0..) } ],
    an_exclusive_range: [ :narrow, -> { where(total_cents: 0...SENTINEL) } ],
    two_conditions_negated: [ :narrow, -> { where.not(status: 4, total_cents: 0) } ],
    arel_comparison: [ :narrow, -> { where(arel_table[:total_cents].gt(0)) } ],
    arel_list: [ :narrow, -> { where(arel_table[:status].in([ 1, 2 ])) } ],
    arel_between: [ :narrow, -> { where(arel_table[:total_cents].between(0..SENTINEL)) } ],
    arel_or: [ :narrow, -> { where(arel_table[:status].eq(1).or(arel_table[:status].eq(2))) } ],
    two_columns_compared: [ :narrow, -> { where(arel_table[:total_cents].gt(arel_table[:status])) } ]
  }.freeze

  QUERY_SHAPES = {
    "a sum" => { "metric" => "revenue" },
    "a count" => { "metric" => "count" },
    "a filter" => { "metric" => "revenue", "filters" => [ { "dimension" => "status", "op" => "gte", "value" => 0 } ] },
    "a group_by" => { "metric" => "revenue", "group_by" => [ { "dimension" => "status" } ] },
    "a path" => { "metric" => "revenue", "group_by" => [ { "dimension" => "customer.name" } ] },
    "a top N" => { "metric" => "revenue", "group_by" => [ { "dimension" => "status" } ], "order_by" => { "by" => "metric", "dir" => "desc" }, "limit" => 1 },
    # Two queries: the second one is as much of a target as the first.
    "a comparison" => { "metric" => "revenue", "period" => { "dimension" => "ordered_at", "range" => { "last" => { "n" => 1, "unit" => "day" } } }, "compare" => "previous_period" }
  }.freeze

  before(:all) do
    Object.const_set(:SpecVector, Class.new(ApplicationRecord))
    SpecVector.class_eval do
      self.table_name = "orders"
      belongs_to :account
      belongs_to :customer

      # Prefixed: Rails refuses a scope named like one of its own methods (none, group, ...).
      SCOPE_VECTORS.each { |name, (_expected, body)| scope :"v_#{name}", body }
    end
  end

  after(:all) { Object.send(:remove_const, :SpecVector) }

  let(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }
  let(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }

  before do
    alice = acme.customers.create!(name: "Alice", email: "alice@example.test", city: "Paris")
    other = globex.customers.create!(name: "Other", email: "other@example.test", city: "Paris")
    [ [ 1, 1000 ], [ 1, 500 ], [ 2, 3000 ] ].each do |status, total|
      acme.orders.create!(customer: alice, status: status, total_cents: total, ordered_at: Time.current)
    end
    3.times { globex.orders.create!(customer: other, status: 1, total_cents: SENTINEL, ordered_at: Time.current) }
    # In the previous period of the "comparison" shape: there, the previous value is the one that would leak.
    globex.orders.create!(customer: other, status: 1, total_cents: SENTINEL, ordered_at: 1.day.ago)
  end

  def catalog_for(model, segments: [], dimensions: [ DataTeller::Dimension.new(name: :status, group: true), DataTeller::Dimension.new(name: :ordered_at) ])
    registry = DataTeller::Registry.new
    registry.register(DataTeller::Dataset.new(model_name: model, roles: %i[admin], tenant_path: %i[account], segments: segments, dimensions: dimensions,
                                              metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count),
                                                         DataTeller::Metric.new(name: :revenue, aggregation: :sum, column: :total_cents) ]))
    registry.register(DataTeller::Dataset.new(model_name: "Customer", roles: %i[admin], tenant_path: %i[account],
                                              dimensions: [ DataTeller::Dimension.new(name: :name, group: true) ]))
    DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
  end

  # :refused, or the rows that came out.
  def attempt(catalog, dataset, shape, extra_filters: [])
    query = { "version" => 1, "intent" => "answer", "dataset" => dataset }.merge(shape)
    query["filters"] = Array(query["filters"]) + extra_filters
    model = catalog.dataset(dataset).model_name.constantize

    DataTeller::ReadOnlyExecution.run(model, timeout: 5) do
      DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current).call(query).execute.rows
    end
  rescue DataTeller::Compiler::Refused, ActiveRecord::StatementInvalid
    :refused
  ensure
    expect(Order.where(account: acme).sum(:total_cents)).to eq(OWN_TOTAL) # nothing was written, whatever happened
  end

  def expect_no_leak(outcome)
    return if outcome == :refused

    expect(outcome.flatten.grep(Numeric).select { |value| value >= SENTINEL }).to eq([])
    expect(outcome.flatten).not_to include("Other")
    expect(outcome.flatten.grep(Numeric).sum).to be <= OWN_TOTAL + 3 # the sum over the tenant's rows, or their count
  end

  describe "hostile scopes, against every query shape" do
    SCOPE_VECTORS.each do |vector, (expected, _body)|
      QUERY_SHAPES.each do |label, shape|
        it "#{vector} with #{label}: #{expected}" do
          segment = DataTeller::Segment.new(name: :x, scope: :"v_#{vector}", roles: :admin)
          outcome = attempt(catalog_for("SpecVector", segments: [ segment ]), "spec_vectors", shape, extra_filters: [ { "segment" => "x" } ])

          expect(outcome).to eq(:refused) if expected == :refuse
          expect(outcome).not_to eq(:refused) if expected == :narrow
          expect_no_leak(outcome)
        end
      end
    end

    # Whatever the declaration says, rake data_teller:check must say the same thing as the compiler.
    SCOPE_VECTORS.each do |vector, (expected, _body)|
      it "#{vector} is #{expected == :refuse ? 'reported' : 'accepted'} by rake data_teller:check" do
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "SpecVector", roles: %i[admin], tenant_path: %i[account],
                                                  segments: [ DataTeller::Segment.new(name: :x, scope: :"v_#{vector}", roles: :admin) ]))
        errors = DataTeller::SchemaValidator.new(registry: registry).call

        expect(errors.grep(/segment x/)).to(expected == :refuse ? be_present : be_empty)
      end
    end

    it "keeps two scopes on the same column as two conditions, in either order" do
      segments = [ DataTeller::Segment.new(name: :a, scope: :v_plain_condition, roles: :admin),
                   DataTeller::Segment.new(name: :b, scope: :v_where_another_tenant, roles: :admin) ]
      filters = [ { "segment" => "a" }, { "segment" => "b" } ]

      expect(attempt(catalog_for("SpecVector", segments: segments), "spec_vectors", { "metric" => "count", "filters" => filters })).to eq([ [ 0 ] ])
      expect(attempt(catalog_for("SpecVector", segments: segments), "spec_vectors", { "metric" => "count", "filters" => filters.reverse })).to eq([ [ 0 ] ])
    end
  end

  # A default_scope applies without anyone naming it, so the same whitelist goes for it (ADR 0004 D4).
  describe "default_scope" do
    DEFAULT_SCOPES = {
      from_redefining_the_tenant_column: [ :refuse, -> { from("(SELECT id, customer_id, total_cents, status, ship_on, ordered_at, #{Account.find_by!(name: "Acme").id} AS account_id FROM orders) orders") } ],
      cte: [ :refuse, -> { with(orders: Order.unscoped.select(:id)) } ],
      group: [ :refuse, -> { group(:customer_id) } ],
      joins: [ :refuse, -> { joins("INNER JOIN customers c ON true") } ],
      raw_breaking_out: [ :refuse, -> { where("1=1) OR (1=1") } ],
      raw_comment: [ :refuse, -> { where("1=1) --") } ],
      raw_comment_block: [ :refuse, -> { where("1=1 /* x") } ],
      raw_statement_end: [ :refuse, -> { where("1=1; SELECT 1") } ],
      # Regressions from the third review.
      raw_in_an_attribute_name: [ :refuse, -> { where(arel_table[Arel.sql("id = id OR 1")].eq(1)) } ],
      or_without_parentheses: [ :refuse, -> { where(Arel::Nodes::Or.new([ arel_table[:id].gt(0), arel_table[:id].lt(0) ])) } ],
      bound_raw_breaking_out: [ :refuse, -> { where("1=1) OR (1=?", 1) } ],
      raw_next_to_an_and: [ :refuse, -> { where(arel_table[:status].eq(1).and(Arel.sql("1=1 OR 1=1"))) } ],
      exists_reading_another_tenant: [ :refuse, -> { where(Order.unscoped.where(total_cents: SENTINEL).arel.exists) } ],
      bound_sub_query: [ :refuse, -> { where("id IN (?)", Order.unscoped.select(:id)) } ],
      a_list: [ :narrow, -> { where(status: [ 1, 2 ]) } ],
      bound_raw_sql: [ :narrow, -> { where("orders.total_cents >= ?", 0) } ],
      named_bound_raw_sql: [ :narrow, -> { where("orders.total_cents >= :min", min: 0) } ],
      order: [ :narrow, -> { order(:ordered_at) } ],
      soft_delete_shaped_raw_sql: [ :narrow, -> { where("orders.total_cents >= 0") } ],
      plain_condition: [ :narrow, -> { where(status: 1) } ]
    }.freeze

    DEFAULT_SCOPES.each do |vector, (expected, body)|
      QUERY_SHAPES.each do |label, shape|
        it "#{vector} with #{label}: #{expected}" do
          model = Class.new(ApplicationRecord)
          stub_const("SpecDefaultScope", model)
          model.class_eval do
            self.table_name = "orders"
            belongs_to :account
            belongs_to :customer
            default_scope(&body)
          end

          outcome = attempt(catalog_for("SpecDefaultScope"), "spec_default_scopes", shape)

          expect(outcome).to eq(:refused) if expected == :refuse
          expect(outcome).not_to eq(:refused) if expected == :narrow
          expect_no_leak(outcome)
        end
      end
    end

    it "applies to a joined table too" do
      model = Class.new(ApplicationRecord)
      stub_const("SpecHostileCustomer", model)
      model.class_eval do
        self.table_name = "customers"
        belongs_to :account
        default_scope { where("1=1) OR (1=1") }
      end
      orders = Class.new(ApplicationRecord)
      stub_const("SpecJoiningOrder", orders)
      orders.class_eval do
        self.table_name = "orders"
        belongs_to :account
        belongs_to :customer, class_name: "SpecHostileCustomer"
      end
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "SpecJoiningOrder", roles: %i[admin], tenant_path: %i[account],
                                                metrics: [ DataTeller::Metric.new(name: :revenue, aggregation: :sum, column: :total_cents) ]))
      registry.register(DataTeller::Dataset.new(model_name: "SpecHostileCustomer", roles: %i[admin], tenant_path: %i[account],
                                                dimensions: [ DataTeller::Dimension.new(name: :name, group: true) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")

      expect(attempt(catalog, "spec_joining_orders", { "metric" => "revenue", "group_by" => [ { "dimension" => "customer.name" } ] })).to eq(:refused)
    end
  end

  # What the LLM controls: values. They must never change the query, whatever the operator.
  describe "hostile values, against every operator" do
    let(:user) { Struct.new(:account, :roles).new(acme, [ :admin ]) }

    VALUES = [
      "' OR 1=1 --", "'; DROP TABLE orders; --", "x') OR ('1'='1", "%", "_", "\\", "\\%", "%' OR '1'='1", "/* */", "$1",
      "\u0000", "Par\u0000is", "é" * 200, "‮", "\n", "' UNION SELECT * FROM accounts --"
    ].freeze

    VALUES.each do |value|
      %w[eq not_eq contains in not_in].each do |operator|
        it "#{operator} with #{value.inspect[0, 30]}" do
          filter = { "dimension" => "customer.city", "op" => operator, "value" => %w[in not_in].include?(operator) ? [ value ] : value }
          query = { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "revenue", "filters" => [ filter ] }

          outcome = DataTeller::QueryRunner.call(query, user: user)

          expect(%i[answered refused]).to include(outcome.status)
          expect(outcome.result.value).to be <= OWN_TOTAL if outcome.result
          expect(Order.where(account: globex).count).to eq(4)
        end
      end
    end

    it "refuses a NUL byte, which the database driver cannot take" do
      query = { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "count",
                "filters" => [ { "dimension" => "customer.city", "op" => "eq", "value" => "Par\u0000is" } ] }

      expect(DataTeller::QueryRunner.call(query, user: user).refusal.reason).to eq(:unsupported_query)
    end
  end

  describe "every tenant, every shape, on the declared dummy app" do
    let(:base) { { "version" => 1, "intent" => "answer", "dataset" => "orders" } }

    {
      "a count" => [ { "metric" => "count" }, 3, 4 ],
      "a sum" => [ { "metric" => "revenue" }, OWN_TOTAL, SENTINEL * 4 ],
      "a filter on a path" => [ { "metric" => "count", "filters" => [ { "dimension" => "customer.city", "op" => "eq", "value" => "Paris" } ] }, 3, 4 ],
      "a segment" => [ { "metric" => "count", "filters" => [ { "segment" => "paid" } ] }, 2, 4 ],
      "a distinct count" => [ { "metric" => "customers" }, 1, 1 ]
    }.each do |label, (shape, for_acme, for_globex)|
      it "gives each tenant its own answer, with #{label}" do
        acme_user = Struct.new(:account, :roles).new(acme, [ :admin ])
        globex_user = Struct.new(:account, :roles).new(globex, [ :admin ])

        expect(DataTeller::QueryRunner.call(base.merge(shape), user: acme_user).result.value).to eq(for_acme)
        expect(DataTeller::QueryRunner.call(base.merge(shape), user: globex_user).result.value).to eq(for_globex)
      end
    end
  end
end
