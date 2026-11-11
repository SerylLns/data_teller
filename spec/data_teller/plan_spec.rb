require "rails_helper"

# What a plan gives the isolation kit (ADR 0011 D5): the rows behind an answer, by primary key, and the tables its SQL reads.
RSpec.describe DataTeller::Plan do
  let(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }
  let(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }
  let(:catalog) { DataTeller::Catalog.new([ :admin ], registry: DataTeller.registry, tenant_model_name: "Account") }

  let!(:alice) { acme.customers.create!(name: "Alice", email: "alice@example.test") }
  let!(:bob) { acme.customers.create!(name: "Bob", email: "bob@example.test") }
  let!(:orders) { [ alice, alice, bob ].map { |customer| order(acme, customer) } }

  before { order(globex, globex.customers.create!(name: "Other", email: "other@example.test")) }

  def order(account, customer)
    account.orders.create!(customer: customer, status: 1, total_cents: 100, ordered_at: Time.current)
  end

  def compile(shape)
    query = { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "revenue" }.merge(shape)
    DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current).call(query)
  end

  def read_keys(plan, cap: 100)
    DataTeller::ReadOnlyExecution.run(Order, timeout: 5) { plan.row_keys(cap: cap) }
  end

  let(:by_customer) { { "group_by" => [ { "dimension" => "customer.name" } ] } }

  describe "#row_keys" do
    it "gives one primary key per table touched, for the tenant's rows only" do
      keys = read_keys(compile(by_customer))

      expect(keys.datasets.map(&:name)).to eq(%i[customers orders])
      expect(keys.rows).to contain_exactly([ alice.id, orders[0].id ], [ alice.id, orders[1].id ], [ bob.id, orders[2].id ])
      expect(keys).to have_attributes(truncated: false, unkeyed: [])
    end

    # A top 1 reads every order to rank the customers: each of those rows must be checked, not only the winner's.
    it "reads every row the aggregate reads, whatever the query's own limit" do
      keys = read_keys(compile(by_customer.merge("limit" => 1)))

      expect(keys.rows.map(&:last)).to match_array(orders.map(&:id))
    end

    it "says when it stopped at the cap" do
      expect(read_keys(compile({}), cap: 2)).to have_attributes(rows: have_attributes(size: 2), truncated: true)
      expect(read_keys(compile({}), cap: 3)).to have_attributes(rows: have_attributes(size: 3), truncated: false)
    end

    it "sets aside a dataset with no single primary key rather than skipping it silently" do
      stub_const("KeylessOrder", Class.new(ApplicationRecord) { self.table_name = "orders"; self.primary_key = nil })
      keyless = Struct.new(:name, :model_name).new(:keyless_orders, "KeylessOrder")
      plan = described_class.new(relation: Order.where(account_id: acme.id), columns: [], selection: [], decoders: [], limit: nil,
                                 touched: [ keyless, catalog.dataset("orders").dataset ])

      expect(read_keys(plan)).to have_attributes(unkeyed: [ keyless ], rows: match_array(orders.map { |one| [ one.id ] }))
    end
  end

  describe "#tables_read" do
    it "lists the tables of the FROM and the JOINs, as the SQL has them" do
      plan = compile(by_customer)

      expect(plan.tables_read).to eq(%w[orders customers])
      expect(plan.touched.map { |dataset| dataset.model_name.constantize.table_name }).to match_array(plan.tables_read)
    end

    # The comparison the kit makes: a joined table no tenant filter was built for.
    it "names a join the compiler did not plan, so that it matches no touched dataset" do
      plan = described_class.new(relation: Order.joins(:customer).joins("INNER JOIN products ON true"), columns: [], selection: [],
                                 decoders: [], limit: nil, touched: [ catalog.dataset("orders").dataset ])

      expect(plan.tables_read).to match([ "orders", "customers", start_with("(not a table") ])
    end

    # The alias has the table's name, its rows are whatever the sub-query chose: it must not pass for the table.
    it "does not take a sub-query named like the table for the table" do
      plan = described_class.new(relation: Order.from(Order.unscoped.arel.as("orders")), columns: [], selection: [], decoders: [],
                                 limit: nil, touched: [ catalog.dataset("orders").dataset ])

      expect(plan.tables_read).to match([ start_with("(not a table") ])
    end
  end

  it "gives both periods of a comparison to the kit" do
    compared = compile("period" => { "dimension" => "ordered_at", "range" => { "last" => { "n" => 1, "unit" => "day" } } },
                       "compare" => "previous_period")

    expect(compared.plans).to all(be_a(described_class))
    expect(compared.plans.map(&:period).uniq.size).to eq(2)
  end
end
