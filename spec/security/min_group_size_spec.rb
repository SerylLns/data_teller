require "rails_helper"

# A minimum group size (ADR 0012), on real rows. Customers are protected at 3, counted as themselves; orders are protected at 3, counted by
# customer. support is held to both thresholds, admin is exempt.
RSpec.describe "Minimum group size" do
  let(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }
  let(:now) { Time.utc(2026, 11, 13, 12) }

  let(:registry) do
    DataTeller::Registry.new.tap do |registry|
      registry.register(DataTeller::Dataset.new(
        model_name: "Customer", roles: %i[admin support], tenant_path: %i[account],
        min_group_size: DataTeller::MinGroupSize.new(minimum: 3, except: %i[admin]),
        metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count),
                   DataTeller::Metric.new(name: :spent, aggregation: :sum, column: "orders.total_cents") ],
        dimensions: [ DataTeller::Dimension.new(name: :city, group: true) ]
      ))
      registry.register(DataTeller::Dataset.new(
        model_name: "Order", roles: %i[admin support], tenant_path: %i[account],
        metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count), DataTeller::Metric.new(name: :revenue, aggregation: :sum, column: :total_cents) ],
        dimensions: [ DataTeller::Dimension.new(name: :status), DataTeller::Dimension.new(name: :ordered_at, time: true) ]
      ))
    end.freeze!
  end

  # Paris: 4 customers, 1 order each. Lyon: 2 customers, 10 orders between them. Nice: 1 customer, 1 order.
  before do
    { "Paris" => [ 1, 1, 1, 1 ], "Lyon" => [ 5, 5 ], "Nice" => [ 1 ] }.each do |city, orders|
      orders.each_with_index do |count, index|
        customer = acme.customers.create!(name: "#{city} #{index}", email: "#{city}#{index}@example.test", city: city)
        count.times { acme.orders.create!(customer: customer, status: 1, total_cents: 100, ordered_at: now - 1.day) }
      end
    end
  end

  def run(query, roles: %i[support], registry: self.registry)
    catalog = DataTeller::Catalog.new(roles, registry: registry, tenant_model_name: "Account")
    query = { "version" => 1, "intent" => "answer", "metric" => "count" }.merge(query)
    DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: now).call(query).execute
  end

  def by_city(dataset = "customers", **extra)
    dimension = dataset == "customers" ? "city" : "customer.city"
    { "dataset" => dataset, "group_by" => [ { "dimension" => dimension } ] }.merge(extra.transform_keys(&:to_s))
  end

  def refused_with(reason) = raise_error(DataTeller::Compiler::Refused) { |error| expect(error.reason).to eq(reason) }

  it "leaves the small groups out and says how many" do
    result = run(by_city)

    expect(result.rows).to eq([ [ "Paris", 4 ] ])
    expect(result.suppressed).to eq(2)
  end

  it "shows everything to an exempt role, and to a user who has one exempt role among others" do
    expect(run(by_city, roles: %i[admin]).rows.map(&:first)).to contain_exactly("Paris", "Lyon", "Nice")
    expect(run(by_city, roles: %i[support admin])).to have_attributes(suppressed: 0)
  end

  it "builds the top N from the groups that may be shown" do
    expect(run(by_city.merge("limit" => 1, "order_by" => { "by" => "metric", "dir" => "asc" })).rows).to eq([ [ "Paris", 4 ] ])
  end

  # Lyon has 10 orders but 2 customers: orders declare no threshold, the joined customers do (D4).
  it "applies the threshold of a joined dataset, counted by its own unit" do
    result = run(by_city("orders"))

    expect(result.rows).to eq([ [ "Paris", 4 ] ])
    expect(result.suppressed).to eq(2)
  end

  # Rows only where they are the dataset's own: a has_many on the metric path repeats each customer once per order, and Lyon's 2 customers
  # would pass as 10.
  it "counts the dataset's rows, not the rows a metric path repeats" do
    result = run(by_city.merge("metric" => "spent"))

    expect(result.rows).to eq([ [ "Paris", 400 ] ])
    expect(result.suppressed).to eq(2)
  end

  it "counts a declared unit, not rows" do
    by_customer = DataTeller::MinGroupSize.new(minimum: 3, of: :customer, except: %i[admin])
    registry = DataTeller::Registry.new.tap do |one|
      one.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[support], tenant_path: %i[account], min_group_size: by_customer,
                                           metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ]))
    end.freeze!
    lyon = acme.customers.where(city: "Lyon").first

    # Lyon's first customer alone has 5 orders: enough rows, one person.
    expect { run({ "dataset" => "orders" }.merge("filters" => []), registry: registry) }.not_to raise_error
    acme.orders.where.not(customer: lyon).delete_all
    expect { run({ "dataset" => "orders" }, registry: registry) }.to refused_with(:group_too_small)
  end

  # The aggregate reads the rows of the small groups too: the isolation kit has to check them (ADR 0011 D5).
  it "leaves the isolation kit every row the aggregate reads" do
    catalog = DataTeller::Catalog.new(%i[support], registry: registry, tenant_model_name: "Account")
    plan = DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: now)
                               .call({ "version" => 1, "intent" => "answer", "metric" => "count" }.merge(by_city))
    keys = DataTeller::ReadOnlyExecution.run(Customer, timeout: 5) { plan.row_keys(cap: 100) }

    expect(keys.rows.flatten).to match_array(acme.customers.ids)
  end

  # The cost estimate reads Plan#statements before anything runs (ADR 0013 D3): it must hold what execute sends, the count of the
  # hidden groups included.
  describe "the statements a plan declares" do
    def plan_for(query)
      catalog = DataTeller::Catalog.new(%i[support], registry: registry, tenant_model_name: "Account")
      DataTeller::Compiler.new(catalog: catalog, tenant: acme, time_zone: ActiveSupport::TimeZone["UTC"], now: now)
                          .call({ "version" => 1, "intent" => "answer", "metric" => "count" }.merge(query))
    end

    def sent_by(plan) = [].tap { |sent| plan.execute(recorder: ->(sql) { sent << sql }) }

    it "are the ones it sends, the count of hidden groups included" do
      plan = plan_for(by_city)

      expect(plan.statements.size).to eq(2)
      expect(plan.statements).to eq(sent_by(plan))
    end

    # The previous period is narrowed to the groups shown once the current one ran: it is declared whole, which reads no fewer rows.
    it "hold both periods of a compare, the previous one whole" do
      plan = plan_for(by_city("orders", period: { "dimension" => "ordered_at", "range" => { "last" => { "n" => 7, "unit" => "day" } } },
                                        compare: "previous_period"))
      sent = sent_by(plan)

      expect(plan.statements.size).to eq(sent.size)
      expect(plan.statements.first(2)).to all(be_in(sent))
      expect(plan.statements.last).not_to include(" IN (")
    end
  end

  describe "a single value" do
    def in_city(city) = { "dataset" => "customers", "filters" => [ { "dimension" => "city", "op" => "eq", "value" => city } ] }

    it "is shown at the threshold and refused under it" do
      expect(run(in_city("Paris")).value).to eq(4)
      expect { run(in_city("Lyon")) }.to refused_with(:group_too_small)
    end

    # If 0 were shown and 1 to 4 hidden, "hidden" would mean "at least one" (D4).
    it "is refused at zero too" do
      expect { run(in_city("Atlantis")) }.to refused_with(:group_too_small)
      expect(run(in_city("Atlantis"), roles: %i[admin]).value).to eq(0)
    end
  end

  describe "compare" do
    let(:last_week) { { "dimension" => "ordered_at", "range" => { "last" => { "n" => 7, "unit" => "day" } } } }

    # Nothing happened the week before: the previous value is under the threshold, so the change would give it away.
    it "refuses a single value when the previous period is under the threshold" do
      expect { run({ "dataset" => "orders", "period" => last_week, "compare" => "previous_period" }, registry: registry_with_order_threshold) }
        .to refused_with(:group_too_small)
    end

    it "leaves out a group that is under the threshold in either period, and counts it" do
      paris = acme.customers.where(city: "Paris")
      paris.each { |customer| acme.orders.create!(customer: customer, status: 1, total_cents: 100, ordered_at: now - 10.days) }

      result = run(by_city("orders", period: last_week, compare: "previous_period"))

      expect(result.rows).to eq([ [ "Paris", 4, 4 ] ])
      expect(result.suppressed).to eq(2)

      # Two customers of Paris the week before: under the threshold then, so Paris goes too.
      acme.orders.where(customer: paris.first(2), ordered_at: ...(now - 7.days)).delete_all
      expect(run(by_city("orders", period: last_week, compare: "previous_period"))).to have_attributes(rows: [], suppressed: 3)
    end

    def registry_with_order_threshold
      DataTeller::Registry.new.tap do |one|
        one.register(DataTeller::Dataset.new(
          model_name: "Order", roles: %i[support], tenant_path: %i[account],
          min_group_size: DataTeller::MinGroupSize.new(minimum: 3, of: :customer),
          metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
          dimensions: [ DataTeller::Dimension.new(name: :ordered_at, time: true) ]
        ))
      end.freeze!
    end
  end
end
