require "rails_helper"

# Lists (ADR 0016): rows one by one, so every row must be the tenant's, every page must follow the last without repeating or skipping
# a row, and the cursor the client sends back is as untrusted as the model's output.
RSpec.describe "Lists" do
  let(:acme) { Account.create!(name: "Acme", time_zone: "Europe/Paris") }
  let(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }
  let(:noon) { Time.utc(2026, 11, 24, 12) }

  let!(:acme_orders) do
    lyon = acme.customers.create!(name: "Alice", email: "alice@example.test", city: "Lyon")
    nowhere = acme.customers.create!(name: "Bob", email: "bob@example.test", city: nil)
    [
      [ lyon, :paid, noon - 3.days, Date.new(2026, 11, 25) ],
      [ lyon, :shipped, noon - 1.day, nil ],
      [ nowhere, :paid, noon - 1.day, Date.new(2026, 11, 26) ],
      [ nowhere, :cancelled, noon - 2.days, nil ],
      [ lyon, :pending, noon - 1.day, Date.new(2026, 11, 25) ]
    ].map do |customer, status, at, ship_on|
      acme.orders.create!(customer: customer, status: status, total_cents: 100, ordered_at: at, ship_on: ship_on)
    end
  end

  let!(:globex_order) do
    other = globex.customers.create!(name: "Other", email: "other@example.test", city: "Lyon")
    globex.orders.create!(customer: other, status: :paid, total_cents: 999_999, ordered_at: noon - 1.day, ship_on: Date.new(2026, 11, 25))
  end

  def registry(customers_protected: false)
    DataTeller::Registry.new.tap do |registry|
      registry.register(DataTeller::Dataset.new(
        model_name: "Order", roles: %i[admin support], tenant_path: %i[account],
        metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
        dimensions: [ dim(:status), dim(:ordered_at, time: true), dim(:ship_on), dim(:total_cents) ],
        list: DataTeller::ListDeclaration.new(default: %i[ordered_at status customer.city])
      ))
      registry.register(DataTeller::Dataset.new(
        model_name: "Customer", roles: %i[admin support], tenant_path: %i[account], dimensions: [ dim(:city) ],
        min_group_size: (DataTeller::MinGroupSize.new(minimum: 5, except: %i[admin]) if customers_protected)
      ))
    end.freeze!
  end

  def dim(name, **options) = DataTeller::Dimension.new(name: name, **options)

  def list(**rest) = { "version" => 1, "intent" => "answer", "dataset" => "orders", "list" => true }.merge(rest.transform_keys(&:to_s))

  def compile(query, after: nil, tenant: acme, role: :admin, **options)
    catalog = DataTeller::Catalog.new([ role ], registry: registry(**options), tenant_model_name: "Account")
    DataTeller::Compiler.new(catalog: catalog, tenant: tenant, time_zone: ActiveSupport::TimeZone[tenant.time_zone], now: noon)
                        .call(query, after: after)
  end

  def run(query, after: nil, **options)
    plan = compile(query, after: after, **options)
    DataTeller::ReadOnlyExecution.run(Order, timeout: 5) { plan.execute }
  end

  # Every page, following each cursor, as a client would.
  def every_page(query, page_size:, **options)
    allow(DataTeller.config).to receive(:max_list_rows).and_return(page_size)
    pages = [ run(query, **options) ]
    pages << run(query, after: pages.last.after, **options) while pages.last.after && pages.size < 20
    pages
  end

  before { allow(DataTeller).to receive(:config).and_return(DataTeller.config.dup) }

  it "lists the tenant's rows only, newest first, enum names and dates in the tenant's zone, with the total" do
    result = run(list(columns: %w[ordered_at status total_cents]))

    expect(result.columns).to eq(%w[ordered_at status total_cents])
    expect(result.rows.map { |row| row[2] }).to all(eq(100))
    expect(result.rows.size).to eq(5)
    expect(result.total).to eq(5)
    expect(result.after).to be_nil
    expect(result.rows.first[0]).to eq((noon - 1.day).in_time_zone("Europe/Paris"))
    expect(result.rows.first[0].time_zone.name).to eq("Europe/Paris")
    expect(result.rows.map { |row| row[1] }).to match_array(%w[paid shipped paid cancelled pending])
  end

  it "shows the default columns, a path's column through its own tenant filter" do
    plan = compile(list)

    expect(plan.columns).to eq(%w[ordered_at status customer.city])
    expect(plan.touched.map(&:name)).to contain_exactly(:orders, :customers)
    expect(plan.to_sql.scan('"account_id" =').size).to be >= 2
    expect(run(list).rows.map(&:last)).to match_array([ "Lyon", "Lyon", "Lyon", nil, nil ])
  end

  it "reads none of another tenant's rows, whatever the cursor says" do
    forged = { "values" => [ (noon + 1.day).utc.iso8601(6), globex_order.id + 1 ], "shown" => 1 }

    expect(run(list(columns: %w[total_cents]), after: forged).rows.flatten).to all(eq(100))
    expect(run(list(columns: %w[total_cents]), tenant: globex).rows).to eq([ [ 999_999 ] ])
  end

  it "pages through every row once, in order, ties on the date broken by the key" do
    pages = every_page(list(columns: %w[total_cents]), page_size: 2)

    expect(pages.map { |page| page.rows.size }).to eq([ 2, 2, 1 ])
    expect(pages.map(&:total)).to eq([ 5, nil, nil ])
    expect(pages.flat_map(&:rows).size).to eq(5)

    ordered = Order.where(account: acme).order(ordered_at: :desc, id: :desc).pluck(:ordered_at, :id)
    shown = pages.flat_map { |page| [ page.after ] }.compact.map { |cursor| cursor["values"] }
    expect(shown).to eq([ ordered[1], ordered[3] ].map { |at, id| [ at.utc.iso8601(6), id ] })
  end

  it "pages through a column with empty values, those last in both directions" do
    [ "asc", "desc" ].each do |dir|
      pages = every_page(list(columns: %w[ship_on], order_by: { "by" => "dimension", "dimension" => "ship_on", "dir" => dir }), page_size: 2)
      values = pages.flat_map(&:rows).map(&:first)

      expect(values.size).to eq(5)
      expect(values.last(2)).to eq([ nil, nil ])
      expect(values.first(3)).to eq(dir == "asc" ? values.first(3).sort : values.first(3).sort.reverse)
    end
  end

  it "pages through an enum order by its names" do
    pages = every_page(list(columns: %w[status], order_by: { "by" => "dimension", "dimension" => "status", "dir" => "asc" }), page_size: 2)

    expect(pages.flat_map(&:rows).map(&:first)).to eq(%w[pending paid paid shipped cancelled])
  end

  it "stops at the query's limit, across pages" do
    pages = every_page(list(columns: %w[total_cents], limit: 3), page_size: 2)

    expect(pages.map { |page| page.rows.size }).to eq([ 2, 1 ])
    expect(pages.first.total).to eq(3)
    expect(pages.last.after).to be_nil
  end

  it "refuses a cursor that is not one it gave" do
    [
      nil.to_a, "1", { "values" => [ 1 ], "shown" => 2 }, { "values" => [ "x", nil ], "shown" => 2 },
      { "values" => [ "x", 1 ], "shown" => 0 }, { "values" => [ "x", 1 ], "shown" => "2" }, { "values" => [ { "a" => 1 }, 1 ], "shown" => 2 },
      { "values" => [ "a\u0000", 1 ], "shown" => 2 }, { "values" => [ "a" * 201, 1 ], "shown" => 2 }
    ].each do |cursor|
      expect { compile(list, after: cursor) }.to raise_error(DataTeller::Compiler::Refused) { |error| expect(error.codes).to eq([ :invalid_cursor ]) }
    end
  end

  it "binds the cursor's values, never writes them into the SQL" do
    sql = compile(list, after: { "values" => [ "2026-11-23T12:00:00.000000Z'; DROP TABLE orders; --", 1 ], "shown" => 2 }).to_sql

    expect(sql).not_to include("DROP TABLE")
  end

  it "is refused where min_group_size protects a dataset it reads, unless the role is exempt" do
    expect { compile(list, role: :support, customers_protected: true) }.to raise_error(DataTeller::Compiler::Refused)
    expect(compile(list, role: :admin, customers_protected: true)).to be_a(DataTeller::ListPlan)
    expect(compile(list(columns: %w[status]), role: :support, customers_protected: true)).to be_a(DataTeller::ListPlan)
  end

  it "takes no cursor on an aggregate" do
    aggregate = { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "count" }

    expect { compile(aggregate, after: { "values" => [ 1 ], "shown" => 1 }) }.to raise_error(DataTeller::Compiler::Refused, /only a list has pages/)
  end
end
