require "rails_helper"

RSpec.describe DataTeller::QueryValidator do
  def validate(query, *roles)
    described_class.new(DataTeller::Catalog.for(roles.empty? ? [ :admin ] : roles)).call(query)
  end

  def answer(dataset = "orders", metric = "count", **rest)
    { "version" => 1, "intent" => "answer", "dataset" => dataset, "metric" => metric }.merge(rest.transform_keys(&:to_s))
  end

  def filter(dimension, op, value = :none)
    { "dimension" => dimension, "op" => op }.tap { |f| f["value"] = value unless value == :none }
  end

  def period(range, dimension = "ordered_at") = { "dimension" => dimension, "range" => range }

  RSpec::Matchers.define :be_refused_with do |reason|
    match { |result| !result.ok? && result.refusal.reason == reason }
    failure_message { |result| "expected a refusal with #{reason}, got ok=#{result.ok?} #{result.refusal&.reason} #{result.problems}" }
  end

  RSpec::Matchers.define :be_accepted do
    match(&:ok?)
    failure_message { |result| "expected it to be accepted, got #{result.refusal&.reason} #{result.problems}" }
  end

  describe "numbers no JSON schema can judge" do
    {
      "a filter value" => '{"filters":[{"dimension":"total_cents","op":"gt","value":1e400}]}',
      "a negative one" => '{"filters":[{"dimension":"total_cents","op":"gt","value":-1e400}]}',
      "a value in a list" => '{"filters":[{"dimension":"total_cents","op":"in","value":[1,1e400]}]}',
      "the limit" => '{"limit":1e400}',
      "a period length" => '{"period":{"dimension":"ordered_at","range":{"last":{"n":1e400,"unit":"day"}}}}',
      "the version" => '{"version":1e400}'
    }.each do |label, json|
      it "refuses an infinite number in #{label}, without raising" do
        result = described_class.new(integer_catalog).call(answer.merge(JSON.parse(json)))

        expect(result).to be_refused_with(:unsupported_query)
        expect(result.problems).to eq([ { pointer: "", code: :invalid_structure, reason: :unsupported_query } ])
      end
    end

    # On an integer column, so that the value would reach the check that raised.
    let(:integer_catalog) do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                dimensions: [ DataTeller::Dimension.new(name: :total_cents), DataTeller::Dimension.new(name: :ordered_at, time: true) ]))
      DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
    end

    it "accepts the same filters with finite values, so the refusals above are about the number" do
      expect(described_class.new(integer_catalog).call(answer(filters: [ filter("total_cents", "in", [ 1, 2 ]) ]))).to be_accepted
      expect(described_class.new(integer_catalog).call(answer(filters: [ filter("total_cents", "gt", 1) ]))).to be_accepted
    end
  end

  # ADR 0016: rows, on a dataset that opted in, in columns the role sees, never where min_group_size protects.
  describe "lists" do
    def list_catalog(*roles, customers_protected: false, customers_listable: false)
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(
        model_name: "Order", roles: %i[admin support], tenant_path: %i[account],
        dimensions: [ dimension(:status), dimension(:ordered_at, time: true), dimension(:ship_on), dimension(:total_cents, roles: %i[admin]) ],
        segments: [ DataTeller::Segment.new(name: :paid, where: { status: "paid" }) ],
        list: DataTeller::ListDeclaration.new(default: %i[ordered_at status total_cents])
      ))
      registry.register(DataTeller::Dataset.new(
        model_name: "Customer", roles: %i[admin support], tenant_path: %i[account],
        dimensions: [ dimension(:city), dimension(:email, sensitive: true, roles: %i[admin]) ],
        min_group_size: (DataTeller::MinGroupSize.new(minimum: 5, except: %i[admin]) if customers_protected),
        list: (DataTeller::ListDeclaration.new(default: %i[city]) if customers_listable)
      ))
      DataTeller::Catalog.new(roles, registry: registry.freeze!, tenant_model_name: "Account")
    end

    def dimension(name, **options) = DataTeller::Dimension.new(name: name, **options)

    def list(dataset = "orders", **rest)
      { "version" => 1, "intent" => "answer", "dataset" => dataset, "list" => true }.merge(rest.transform_keys(&:to_s))
    end

    def check(query, *roles, **options) = described_class.new(list_catalog(*roles, **options)).call(query)
    def codes(result) = result.problems.map { |problem| problem[:code] }

    it "accepts the default columns, and columns chosen with a period, filters and an order" do
      expect(check(list, :support)).to be_accepted
      expect(check(list(columns: %w[ordered_at customer.city status], period: period({ "relative" => "tomorrow" }, "ship_on"),
                        filters: [ { "segment" => "paid" }, filter("customer.city", "eq", "Lyon") ],
                        order_by: { "by" => "dimension", "dimension" => "ordered_at", "dir" => "asc" }, limit: 20), :support)).to be_accepted
    end

    it "refuses a dataset that did not opt in" do
      result = check(list("customers"), :admin)

      expect(result).to be_refused_with(:unsupported_query)
      expect(codes(result)).to eq([ :not_listable ])
    end

    # A forbidden column and an unknown one are the same case (ADR 0001 D5).
    it "refuses a column the role does not see, as an unknown one" do
      hidden = check(list(columns: %w[status customer.email]), :support)
      unknown = check(list(columns: %w[status nope]), :support)

      expect(hidden.problems).to eq(unknown.problems)
      expect(codes(hidden)).to eq([ :unknown_dimension ])
      expect(check(list(columns: %w[status customer.email]), :admin)).to be_accepted
    end

    it "orders only by a column the role sees" do
      order = { "by" => "dimension", "dimension" => "total_cents", "dir" => "desc" }

      expect(codes(check(list(order_by: order), :support))).to eq([ :unknown_dimension ])
      expect(check(list(order_by: order), :admin)).to be_accepted
    end

    it "keeps out of the defaults what the role does not see, and refuses when none is left" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin support], tenant_path: %i[account],
                                                dimensions: [ dimension(:total_cents, roles: %i[admin]) ],
                                                list: DataTeller::ListDeclaration.new(default: %i[total_cents])))
      catalog = DataTeller::Catalog.new([ :support ], registry: registry.freeze!, tenant_model_name: "Account")

      expect(codes(described_class.new(catalog).call(list))).to eq([ :no_visible_column ])
    end

    it "is refused on a protected dataset it reads through a column, a filter or the order, unless the role is exempt" do
      through_column = list(columns: %w[ordered_at customer.city])
      through_filter = list(filters: [ filter("customer.city", "eq", "Lyon") ])
      through_order = list(order_by: { "by" => "dimension", "dimension" => "customer.city", "dir" => "asc" })

      [ through_column, through_filter, through_order ].each do |query|
        expect(codes(check(query, :support, customers_protected: true))).to eq([ :protected_rows ])
        expect(check(query, :admin, customers_protected: true)).to be_accepted
      end
      expect(check(list, :support, customers_protected: true)).to be_accepted
    end

    it "is refused on a protected dataset listed itself, unless the role is exempt" do
      expect(codes(check(list("customers"), :support, customers_protected: true, customers_listable: true))).to eq([ :protected_rows ])
      expect(check(list("customers"), :admin, customers_protected: true, customers_listable: true)).to be_accepted
      expect(check(list("customers"), :support, customers_listable: true)).to be_accepted
    end
  end

  describe "structure" do
    [ nil, "orders", 42, [], {}, { "version" => 2, "intent" => "answer", "dataset" => "orders", "metric" => "count" } ].each do |bad|
      it "refuses #{bad.inspect[0, 30]}" do
        expect(validate(bad)).to be_refused_with(:unsupported_query)
      end
    end

    it "does not raise on anything the schema refuses" do
      Dir[Rails.root.join("../fixtures/queries/invalid/*.json")].each do |path|
        expect(validate(JSON.parse(File.read(path)))).to be_refused_with(:unsupported_query)
      end
    end
  end

  describe "dataset and metric" do
    it "accepts what is declared" do
      expect(validate(answer("orders", "revenue"))).to be_accepted
    end

    it "refuses an unknown dataset" do
      expect(validate(answer("quotes"))).to be_refused_with(:unknown_dataset)
    end

    it "refuses a metric of another dataset" do
      expect(validate(answer("customers", "revenue"))).to be_refused_with(:unknown_metric)
    end

    it "refuses everything without a role" do
      expect(described_class.new(DataTeller::Catalog.new([])).call(answer)).to be_refused_with(:unknown_dataset)
    end
  end

  # ADR 0001 D5: refusals never reveal that a forbidden resource exists.
  describe "forbidden and unknown are indistinguishable" do
    {
      "metric" => [ { "metric" => "revenue" }, { "metric" => "does_not_exist" } ],
      "ratio over a forbidden metric" => [ { "metric" => "avg_basket" }, { "metric" => "does_not_exist" } ]
    }.each do |label, (forbidden, unknown)|
      it "for a #{label}" do
        hidden = validate(answer.merge(forbidden), :support)
        missing = validate(answer.merge(unknown), :support)

        expect(hidden.refusal).to eq(missing.refusal)
        expect(hidden.problems).to eq(missing.problems)
      end
    end

    it "for a dimension hidden from the role" do
      catalog = lambda do |roles|
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin support], tenant_path: %i[account],
                                                  metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                  dimensions: [ DataTeller::Dimension.new(name: :status, roles: :admin) ]))
        DataTeller::Catalog.new(roles, registry: registry.freeze!, tenant_model_name: "Account")
      end
      validator = described_class.new(catalog.call([ :support ]))

      hidden = validator.call(answer(filters: [ filter("status", "eq", "paid") ]))
      missing = validator.call(answer(filters: [ filter("nope", "eq", "paid") ]))

      expect(hidden).to be_refused_with(:unsupported_query)
      expect(hidden.problems).to eq(missing.problems)
      expect(described_class.new(catalog.call([ :admin ])).call(answer(filters: [ filter("status", "eq", "paid") ]))).to be_accepted
    end

    it "keeps the names out of the problems, which end up in logs" do
      result = validate(answer("customers", "revenue", filters: [ filter("secret_thing", "eq", "x") ]))

      expect(result.problems.to_s).not_to include("revenue", "secret_thing")
    end
  end

  describe "period" do
    it "accepts a date dimension" do
      expect(validate(answer(period: period({ "relative" => "tomorrow" }, "ship_on")))).to be_accepted
    end

    it "refuses any other dimension" do
      expect(validate(answer(period: period({ "relative" => "tomorrow" }, "status")))).to be_refused_with(:unsupported_query)
    end

    it "refuses a date that is not in the calendar, which the schema cannot see" do
      expect(validate(answer(period: period({ "on" => "2024-02-31" })))).to be_refused_with(:unsupported_query)
      expect(validate(answer(period: period({ "on" => "2024-02-29" })))).to be_accepted
      expect(validate(answer(period: period({ "on" => "2023-02-29" })))).to be_refused_with(:unsupported_query)
    end

    it "refuses a range that ends before it starts" do
      between = ->(from, to) { period({ "between" => { "from" => from, "to" => to } }) }

      expect(validate(answer(period: between.call("2024-03-01", "2024-02-01")))).to be_refused_with(:unsupported_query)
      expect(validate(answer(period: between.call("2024-02-31", "2024-03-01")))).to be_refused_with(:unsupported_query)
      expect(validate(answer(period: between.call("2024-03-01", "2024-03-01")))).to be_accepted
    end
  end

  describe "filters" do
    it "accepts a declared segment, and refuses any other" do
      expect(validate(answer(filters: [ { "segment" => "paid" } ]))).to be_accepted
      expect(validate(answer(filters: [ { "segment" => "nope" } ]))).to be_refused_with(:unsupported_query)
      expect(validate(answer("customers", filters: [ { "segment" => "paid" } ]))).to be_refused_with(:unsupported_query)
    end

    it "accepts a path, and refuses a path to an undeclared column" do
      expect(validate(answer(filters: [ filter("customer.city", "eq", "Paris") ]))).to be_accepted
      expect(validate(answer(filters: [ filter("customer.email", "eq", "a@example.test") ]))).to be_refused_with(:unsupported_query)
    end

    it "refuses date dimensions: time goes through period (ADR 0001 D1)" do
      expect(validate(answer(filters: [ filter("ship_on", "eq", "2024-01-01") ]))).to be_refused_with(:unsupported_query)
    end

    describe "enums" do
      it "accept declared values only (ADR 0001 D2)" do
        expect(validate(answer(filters: [ filter("status", "eq", "paid") ]))).to be_accepted
        expect(validate(answer(filters: [ filter("status", "in", %w[paid shipped]) ]))).to be_accepted
        expect(validate(answer(filters: [ filter("status", "eq", "lost") ]))).to be_refused_with(:unsupported_query)
        expect(validate(answer(filters: [ filter("status", "in", %w[paid lost]) ]))).to be_refused_with(:unsupported_query)
      end

      it "refuse the raw integer behind the enum" do
        expect(validate(answer(filters: [ filter("status", "eq", 1) ]))).to be_refused_with(:unsupported_query)
      end

      it "refuse operators that make no sense" do
        expect(validate(answer(filters: [ filter("status", "gt", "paid") ]))).to be_refused_with(:unsupported_query)
        expect(validate(answer(filters: [ filter("status", "contains", "pa") ]))).to be_refused_with(:unsupported_query)
      end
    end

    describe "text" do
      it "accepts a string, and contains" do
        expect(validate(answer(filters: [ filter("customer.city", "contains", "Par") ]))).to be_accepted
      end

      it "refuses numbers, booleans and ordering" do
        expect(validate(answer(filters: [ filter("customer.city", "eq", 12) ]))).to be_refused_with(:unsupported_query)
        expect(validate(answer(filters: [ filter("customer.city", "eq", true) ]))).to be_refused_with(:unsupported_query)
        expect(validate(answer(filters: [ filter("customer.city", "gt", "A") ]))).to be_refused_with(:unsupported_query)
      end
    end

    describe "numbers" do
      let(:catalog) do
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                  metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                  dimensions: [ DataTeller::Dimension.new(name: :total_cents) ]))
        DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
      end

      it "accept numbers and ordering operators" do
        expect(described_class.new(catalog).call(answer(filters: [ filter("total_cents", "gte", 100) ]))).to be_accepted
      end

      # The bind casts through the column type, so 1000.5 would silently be compared as 1000.
      it "refuse a fraction on an integer column" do
        expect(described_class.new(catalog).call(answer(filters: [ filter("total_cents", "eq", 1000.5) ]))).to be_refused_with(:unsupported_query)
        expect(described_class.new(catalog).call(answer(filters: [ filter("total_cents", "in", [ 1000.9 ]) ]))).to be_refused_with(:unsupported_query)
        expect(described_class.new(catalog).call(answer(filters: [ filter("total_cents", "eq", 1000.0) ]))).to be_accepted
      end

      it "refuse strings and contains" do
        expect(described_class.new(catalog).call(answer(filters: [ filter("total_cents", "gte", "100") ]))).to be_refused_with(:unsupported_query)
        expect(described_class.new(catalog).call(answer(filters: [ filter("total_cents", "contains", 1) ]))).to be_refused_with(:unsupported_query)
      end
    end

    describe "lookups (ADR 0001 D2)" do
      let(:dupont) { { "lookup" => "Dupont" } }

      it "work on a dimension declared with lookup:" do
        expect(validate(answer(filters: [ filter("customer.name", "eq", dupont) ]))).to be_accepted
        expect(validate(answer(filters: [ filter("customer.name", "in", [ dupont ]) ]))).to be_accepted
      end

      it "are refused anywhere else" do
        expect(validate(answer(filters: [ filter("customer.city", "eq", dupont) ]))).to be_refused_with(:unsupported_query)
        expect(validate(answer(filters: [ filter("status", "eq", dupont) ]))).to be_refused_with(:unsupported_query)
      end

      it "are the only way to match an entity exactly: a raw string misses accents and hides homonyms" do
        expect(validate(answer(filters: [ filter("customer.name", "eq", "Dupont") ]))).to be_refused_with(:unsupported_query)
      end

      it "only combine with equality" do
        expect(validate(answer(filters: [ filter("customer.name", "contains", dupont) ]))).to be_refused_with(:unsupported_query)
      end

      it "leave contains available as a plain text search" do
        expect(validate(answer(filters: [ filter("customer.name", "contains", "Dup") ]))).to be_accepted
      end
    end

    it "accepts is_null on any filterable dimension" do
      expect(validate(answer(filters: [ filter("customer.city", "is_null") ]))).to be_accepted
    end
  end

  describe "group_by" do
    def grouped(*items) = answer(group_by: items)
    def by(dimension, granularity = nil) = { "dimension" => dimension, "granularity" => granularity }.compact

    it "accepts a groupable dimension" do
      expect(validate(grouped(by("status")))).to be_accepted
      expect(validate(grouped(by("customer.name")))).to be_accepted
    end

    it "refuses a dimension that is not groupable" do
      expect(validate(grouped(by("customer.city")))).to be_refused_with(:unsupported_query)
    end

    it "needs a granularity on dates: grouping by a timestamp would list rows" do
      expect(validate(grouped(by("ordered_at", "month")))).to be_accepted
      expect(validate(grouped(by("ordered_at")))).to be_refused_with(:unsupported_query)
    end

    it "refuses a granularity on anything else" do
      expect(validate(grouped(by("status", "month")))).to be_refused_with(:unsupported_query)
    end

    it "refuses the same dimension twice" do
      expect(validate(grouped(by("status"), by("status")))).to be_refused_with(:unsupported_query)
    end

    it "allows one high-cardinality dimension with another one" do
      expect(validate(grouped(by("customer.name"), by("status")))).to be_accepted
    end

    it "refuses two high-cardinality dimensions with too_many_groups (ADR 0004 D3)" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ],
                                                dimensions: [ DataTeller::Dimension.new(name: :customer_id, group: true),
                                                              DataTeller::Dimension.new(name: :total_cents, group: true) ]))
      catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")

      expect(described_class.new(catalog).call(grouped(by("customer_id"), by("total_cents")))).to be_refused_with(:too_many_groups)
    end
  end

  describe "order_by" do
    let(:by_status) { { "group_by" => [ { "dimension" => "status" } ] } }

    it "accepts the metric" do
      expect(validate(answer(order_by: { "by" => "metric", "dir" => "desc" }, **by_status.transform_keys(&:to_sym)))).to be_accepted
    end

    it "accepts a dimension of the group_by" do
      expect(validate(answer(order_by: { "by" => "dimension", "dimension" => "status", "dir" => "asc" }, **by_status.transform_keys(&:to_sym)))).to be_accepted
    end

    # Ordering by a hidden column reveals its values, and SQL would refuse it anyway on an aggregate.
    it "refuses a dimension that is not in the group_by" do
      expect(validate(answer(order_by: { "by" => "dimension", "dimension" => "customer.name", "dir" => "asc" }, **by_status.transform_keys(&:to_sym))))
        .to be_refused_with(:unsupported_query)
    end
  end

  describe "compare" do
    let(:with_period) { { period: period({ "relative" => "last_month" }), compare: "previous_period" } }

    it "accepts a value, and a group that exists in both periods" do
      expect(validate(answer(**with_period))).to be_accepted
      expect(validate(answer(**with_period, group_by: [ { "dimension" => "status" } ]))).to be_accepted
    end

    # October's weeks and September's weeks are different groups: nothing lines them up.
    it "refuses a date group, whose values differ between the two periods" do
      expect(validate(answer(**with_period, group_by: [ { "dimension" => "ordered_at", "granularity" => "week" } ]))).to be_refused_with(:unsupported_query)
    end
  end

  describe "clarify" do
    def clarify(*options) = { "version" => 1, "intent" => "clarify", "clarify" => { "reason" => "ambiguous_metric", "options" => options } }

    it "accepts visible names" do
      expect(validate(clarify("count", "revenue"))).to be_accepted
    end

    it "refuses invented options" do
      expect(validate(clarify("count", "margin"))).to be_refused_with(:unsupported_query)
    end

    it "refuses a name the role cannot see: asking would reveal it" do
      expect(validate(clarify("count", "revenue"), :support)).to be_refused_with(:unsupported_query)
    end
  end

  it "lets out_of_scope through" do
    query = { "version" => 1, "intent" => "out_of_scope", "out_of_scope" => { "reason" => "not_a_data_question" } }

    expect(validate(query)).to be_accepted
  end

  it "reports every problem, and refuses for the most specific reason" do
    result = validate(answer("orders", "margin", filters: [ filter("status", "eq", "lost"), filter("nope", "eq", 1) ]))

    expect(result).to be_refused_with(:unknown_metric)
    expect(result.problems.map { |problem| problem[:pointer] }).to contain_exactly("/metric", "/filters/0/value", "/filters/1/dimension")
  end
end
