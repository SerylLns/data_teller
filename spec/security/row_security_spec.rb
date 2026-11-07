require "rails_helper"

# T39: the database holds the tenant line on its own. The compiler's tenant filter is switched off here, as a bug or a hostile
# scope would: without row security another tenant's rows come out, with it they do not. The policies are the ones
# `rake data_teller:grants` prints, applied inside the spec's transaction and rolled back with it.
RSpec.describe "Row-level security" do
  include ActiveSupport::Testing::TimeHelpers

  let(:role) { "data_teller_spec_reader" }
  let(:user_class) { Struct.new(:account, :roles) }
  let(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }
  let(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }
  let(:admin) { user_class.new(acme, [ :admin ]) }

  # Acme: 1000 + 500 + 3000, in two cities. Globex: three orders of a sentinel no sum of Acme's can reach.
  SENTINEL = 1_000_000
  ACME_TOTAL = 4_500

  before do
    travel_to(Time.utc(2026, 11, 4, 12))
    alice = acme.customers.create!(name: "Alice", email: "alice@example.test", city: "Paris")
    bruno = acme.customers.create!(name: "Bruno", email: "bruno@example.test", city: "Lyon")
    other = globex.customers.create!(name: "Other", email: "other@example.test", city: "Paris")
    acme.orders.create!(customer: alice, status: :paid, total_cents: 1000, ordered_at: 2.days.ago)
    acme.orders.create!(customer: alice, status: :shipped, total_cents: 3000, ordered_at: 2.days.ago)
    acme.orders.create!(customer: bruno, status: :paid, total_cents: 500, ordered_at: 40.days.ago)
    3.times { globex.orders.create!(customer: other, status: :paid, total_cents: SENTINEL, ordered_at: 2.days.ago) }
  end

  after { travel_back }

  def execute(sql) = ActiveRecord::Base.with_connection { |connection| connection.execute(sql) }

  def set_up_database(registry = DataTeller.registry)
    member = ActiveRecord::Base.with_connection { |connection| connection.select_value("SELECT current_user") }
    execute(DataTeller::ReaderGrants.new(registry: registry, tenant_model_name: "Account").sql(role: role, member: member))
    execute(DataTeller::RowPolicies.new(registry: registry, tenant_model_name: "Account", role: role).sql)
  end

  def configure(database_role:, row_security:)
    config = DataTeller::Loader.capture do
      DataTeller.configure do |c|
        c.tenant do
          model Account
          resolve { |user| user.account }
          time_zone(&:time_zone)
        end
        c.roles { |user| user.roles }
        c.database_role = database_role
        c.row_security = row_security
      end
    end.config
    allow(DataTeller).to receive(:config).and_return(config)
  end

  # Without row security, as the app's own user: under the role, the policies would refuse every query with no tenant set.
  def ask(query, user: admin, row_security: true)
    configure(database_role: (role if row_security), row_security: row_security)
    DataTeller::QueryRunner.call({ "version" => 1, "intent" => "answer" }.merge(query), user: user)
  end

  # Each filter is still built and checked as present: it just filters nothing.
  def without_the_compilers_tenant_filter
    allow_any_instance_of(DataTeller::TenantScope).to receive(:condition_for) { Arel::Nodes::True.new }
  end

  describe "with the compiler's tenant filter switched off" do
    before do
      set_up_database
      without_the_compilers_tenant_filter
    end

    it "leaks without row security: the switch really is off" do
      expect(ask({ "dataset" => "orders", "metric" => "revenue" }, row_security: false).result.value).to eq(ACME_TOTAL + 3 * SENTINEL)
    end

    {
      "a total" => [ { "dataset" => "orders", "metric" => "revenue" }, ACME_TOTAL ],
      "a count" => [ { "dataset" => "orders", "metric" => "count" }, 3 ],
      "a distinct count over a foreign key" => [ { "dataset" => "orders", "metric" => "customers" }, 2 ],
      "a group through a joined table" => [
        { "dataset" => "orders", "metric" => "revenue", "group_by" => [ { "dimension" => "customer.name" } ] },
        [ [ "Alice", 4000 ], [ "Bruno", 500 ] ]
      ],
      "a filter through a joined table" => [
        { "dataset" => "orders", "metric" => "count", "filters" => [ { "dimension" => "customer.city", "op" => "eq", "value" => "Paris" } ] }, 2
      ],
      "another dataset" => [ { "dataset" => "customers", "metric" => "count" }, 2 ],
      "a comparison" => [
        { "dataset" => "orders", "metric" => "revenue", "period" => { "dimension" => "ordered_at", "range" => { "between" => { "from" => "2026-10-06", "to" => "2026-11-04" } } },
          "compare" => "previous_period" },
        [ [ 4000, 500 ] ]
      ]
    }.each do |label, (query, expected)|
      it "keeps #{label} to the tenant's own rows" do
        outcome = ask(query)

        expect(outcome.status).to eq(:answered), outcome.refusal&.reason.inspect
        expect(expected.is_a?(Array) ? outcome.result.rows : outcome.result.value).to eq(expected)
      end
    end

    it "keeps each tenant to its own rows" do
      gina = user_class.new(globex, [ :admin ])

      expect(ask({ "dataset" => "orders", "metric" => "revenue" }, user: gina).result.value).to eq(3 * SENTINEL)
    end
  end

  # line_items has no account_id: its policy keeps the rows whose order is visible, and the orders' own policy does the rest.
  describe "a table that reaches its tenant through a parent" do
    let(:registry) do
      DataTeller::Registry.new.tap do |registry|
        registry.register(DataTeller::Dataset.new(model_name: "LineItem", roles: %i[admin], tenant_path: %i[order account],
                                                  metrics: [ DataTeller::Metric.new(name: :units, aggregation: :sum, column: :quantity) ]))
      end.freeze!
    end

    before do
      product = acme.products.create!(name: "Mug", category: "Kitchen", price_cents: 100)
      Order.where(account: acme).find_each { |order| order.line_items.create!(product: product, quantity: 2, unit_price_cents: 100) }
      Order.where(account: globex).find_each { |order| order.line_items.create!(product: product, quantity: SENTINEL, unit_price_cents: 1) }
      set_up_database(registry)
      allow(DataTeller::Catalog).to receive(:for_user).and_return(DataTeller::Catalog.new([ :admin ], registry: registry, tenant_model_name: "Account"))
      without_the_compilers_tenant_filter
    end

    it "leaks without row security" do
      expect(ask({ "dataset" => "line_items", "metric" => "units" }, row_security: false).result.value).to eq(6 + 3 * SENTINEL)
    end

    it "keeps to the tenant's own rows with it" do
      expect(ask({ "dataset" => "line_items", "metric" => "units" }).result.value).to eq(6)
    end
  end

  # The policies are installed, the setting says otherwise: no tenant reaches Postgres, and no query gets an answer.
  it "fails closed when row_security is turned off while the policies stay" do
    set_up_database
    configure(database_role: role, row_security: false)
    allow(Rails.logger).to receive(:error)

    outcome = DataTeller::QueryRunner.call({ "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "count" }, user: admin)

    expect(outcome.refusal.reason).to eq(:unsupported_query)
  end

  # Everything the app does goes on as before, for a role that is neither the table's owner nor a superuser.
  it "leaves other roles every row, to read and to write" do
    set_up_database
    execute("CREATE ROLE data_teller_spec_app NOLOGIN")
    execute("GRANT SELECT, UPDATE ON orders TO data_teller_spec_app")

    execute("SET LOCAL ROLE data_teller_spec_app")
    begin
      expect(execute("SELECT count(*) AS n FROM orders").first["n"]).to eq(6)
      expect(execute("UPDATE orders SET status = 3").cmd_tuples).to eq(6)
    ensure
      execute("RESET ROLE")
    end
  end

  it "answers what the compiler answers, on every query of the dummy app, with both on" do
    set_up_database
    queries = [
      { "dataset" => "orders", "metric" => "revenue", "group_by" => [ { "dimension" => "status" } ] },
      { "dataset" => "orders", "metric" => "avg_basket", "group_by" => [ { "dimension" => "ordered_at", "granularity" => "month" } ] },
      { "dataset" => "orders", "metric" => "count", "filters" => [ { "segment" => "paid" } ] },
      { "dataset" => "customers", "metric" => "count", "group_by" => [ { "dimension" => "name" } ] }
    ]

    queries.each do |query|
      configure(database_role: nil, row_security: false)
      plain = DataTeller::QueryRunner.call({ "version" => 1, "intent" => "answer" }.merge(query), user: admin)

      expect(ask(query).result).to eq(plain.result), query.inspect
    end
  end
end
