require "rails_helper"

# Real users, the dummy app's real declarations, every role against every use of every name (ADR 0004 D5).
# A permission applies to every use of a name, not only to display, and every part of the chain must agree.
RSpec.describe "Permissions matrix" do
  let(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }

  def user_with(role) = acme.users.create!(email: "#{role}@acme.example.test", role: role)
  def answer(**rest) = { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "count" }.merge(rest.transform_keys(&:to_s))

  before do
    alice = acme.customers.create!(name: "Alice", email: "alice@example.test", city: "Paris")
    acme.orders.create!(customer: alice, status: :paid, total_cents: 1000, ordered_at: Time.current)
  end

  ALL = %w[admin support member].freeze
  STAFF = %w[admin support].freeze
  ADMIN = %w[admin].freeze

  # What a query does with a name => who may do it, and the refusal for the others.
  USES = {
    "read the implicit count" => [ { "metric" => "count" }, ALL, nil ],
    "read revenue" => [ { "metric" => "revenue" }, ADMIN, :unknown_metric ],
    "read a ratio over revenue" => [ { "metric" => "avg_basket" }, ADMIN, :unknown_metric ],
    "read distinct customers" => [ { "metric" => "customers" }, STAFF, :unknown_metric ],
    "open the customers dataset" => [ { "dataset" => "customers" }, STAFF, :unknown_dataset ],

    "filter on status" => [ { "filters" => [ { "dimension" => "status", "op" => "eq", "value" => "paid" } ] }, ALL, nil ],
    "use a segment" => [ { "filters" => [ { "segment" => "paid" } ] }, ALL, nil ],
    "group by status" => [ { "group_by" => [ { "dimension" => "status" } ] }, ALL, nil ],
    "use a period" => [ { "period" => { "dimension" => "ordered_at", "range" => { "relative" => "today" } } }, ALL, nil ],

    # Each way to reach a column of a dataset the role cannot see. Filtering alone would reveal its values by bisection.
    "filter through a hidden dataset" => [ { "filters" => [ { "dimension" => "customer.city", "op" => "eq", "value" => "Paris" } ] }, STAFF, :unsupported_query ],
    "test for null through a hidden dataset" => [ { "filters" => [ { "dimension" => "customer.city", "op" => "is_null" } ] }, STAFF, :unsupported_query ],
    "search text through a hidden dataset" => [ { "filters" => [ { "dimension" => "customer.name", "op" => "contains", "value" => "A" } ] }, STAFF, :unsupported_query ],
    "group through a hidden dataset" => [ { "group_by" => [ { "dimension" => "customer.name" } ] }, STAFF, :unsupported_query ],
    "order through a hidden dataset" => [ { "group_by" => [ { "dimension" => "customer.name" } ], "order_by" => { "by" => "dimension", "dimension" => "customer.name", "dir" => "asc" } }, STAFF, :unsupported_query ]
  }.freeze

  USES.each do |use, (query, allowed, refusal)|
    ALL.each do |role|
      if allowed.include?(role)
        # group_too_small counts as allowed: the dummy protects customers from support (ADR 0012), and that refusal comes after the
        # query ran, every permission passed. Here a customer or none, so a single value about customers is always under it.
        it "#{role} can #{use}" do
          outcome = DataTeller::QueryRunner.call(answer(**query.transform_keys(&:to_sym)), user: user_with(role))

          expect([ outcome.status, outcome.refusal&.reason ]).to be_in([ [ :answered, nil ], [ :refused, :group_too_small ] ])
        end
      else
        it "#{role} cannot #{use}, and is told the same thing as for something that does not exist" do
          outcome = DataTeller::QueryRunner.call(answer(**query.transform_keys(&:to_sym)), user: user_with(role))

          expect(outcome.refusal.reason).to eq(refusal)
        end
      end
    end
  end

  describe "the same refusal as for something unknown" do
    let(:member) { user_with("member") }

    def refusal_of(**query) = DataTeller::QueryRunner.call(answer(**query), user: member).refusal

    it "for a metric" do
      expect(refusal_of(metric: "revenue")).to eq(refusal_of(metric: "does_not_exist"))
    end

    it "for a dataset" do
      expect(refusal_of(dataset: "customers")).to eq(refusal_of(dataset: "does_not_exist"))
    end

    it "for a dimension" do
      hidden = { "dimension" => "customer.city", "op" => "eq", "value" => "x" }
      unknown = { "dimension" => "customer.nope", "op" => "eq", "value" => "x" }

      expect(refusal_of(filters: [ hidden ])).to eq(refusal_of(filters: [ unknown ]))
    end
  end

  describe "clarify" do
    def clarify(*options) = { "version" => 1, "intent" => "clarify", "clarify" => { "reason" => "ambiguous_metric", "options" => options } }

    # Asking "did you mean revenue?" would tell a member that revenue exists.
    it "cannot offer a name the role cannot see" do
      expect(DataTeller::QueryRunner.call(clarify("count", "revenue"), user: user_with("member")).refusal.reason).to eq(:unsupported_query)
      expect(DataTeller::QueryRunner.call(clarify("count", "revenue"), user: user_with("admin")).status).to eq(:clarify)
    end
  end

  describe "who is asking" do
    it "unions several roles" do
      user = Struct.new(:account, :roles).new(acme, %w[member support])

      expect(DataTeller::QueryRunner.call(answer(metric: "customers"), user: user).status).to eq(:answered)
      expect(DataTeller::QueryRunner.call(answer(metric: "revenue"), user: user).refusal.reason).to eq(:unknown_metric)
    end

    it "gives an unknown role nothing" do
      expect(DataTeller::QueryRunner.call(answer, user: user_with("intern")).refusal.reason).to eq(:unknown_dataset)
    end

    # Permissions are recomputed on every request: a demotion takes effect on the next question.
    it "follows a role change at once" do
      user = user_with("admin")
      expect(DataTeller::QueryRunner.call(answer(metric: "revenue"), user: user).status).to eq(:answered)

      user.update!(role: "member")

      expect(DataTeller::QueryRunner.call(answer(metric: "revenue"), user: user).refusal.reason).to eq(:unknown_metric)
    end

    it "gives nothing when the resolver fails" do
      user = Struct.new(:account) { def roles = raise("directory is down") }.new(acme)
      allow(Rails.logger).to receive(:error)

      expect(DataTeller::QueryRunner.call(answer, user: user).refusal.reason).to eq(:unknown_dataset)
    end

    it "keeps a user of one tenant inside it, whatever the role" do
      globex = Account.create!(name: "Globex", time_zone: "UTC")
      other = globex.customers.create!(name: "Other", email: "other@example.test")
      globex.orders.create!(customer: other, total_cents: 999_999, ordered_at: Time.current)

      expect(DataTeller::QueryRunner.call(answer(metric: "revenue"), user: user_with("admin")).result.value).to eq(1000)
    end
  end

  # One choke point (ADR 0004 D5): what the catalog shows, the schema offers and the validator accepts must be the same thing.
  describe "the chain agrees, for each role" do
    ALL.each do |role|
      describe role do
        let(:catalog) { DataTeller::Catalog.for_user(user_with(role)) }
        let(:schema) { DataTeller::SchemaGenerator.new(catalog).call }
        let(:validator) { DataTeller::QueryValidator.new(catalog) }

        def branch(name) = schema["anyOf"].find { |candidate| candidate.dig("properties", "dataset", "const") == name }
        def names_at(entry, *path) = entry.dig("properties", *path)

        it "offers exactly the metrics the catalog shows" do
          catalog.datasets.each do |entry|
            expect(names_at(branch(entry.name.to_s), "metric", "enum")).to match_array(entry.metrics.map { |metric| metric.name.to_s })
          end
        end

        it "offers exactly the datasets the catalog shows" do
          offered = schema["anyOf"].filter_map { |candidate| candidate.dig("properties", "dataset", "const") }

          expect(offered).to match_array(catalog.datasets.map { |entry| entry.name.to_s })
        end

        it "does not mention a name the role cannot see, anywhere in the schema" do
          everything = %w[revenue avg_basket customers customer.city customer.name]
          visible = catalog.datasets.flat_map { |entry| entry.metrics.map(&:name) + entry.fields.map(&:name) + [ entry.name ] }.map(&:to_s)

          (everything - visible).each { |hidden| expect(schema.to_json).not_to include(%("#{hidden}")) }
        end

        it "accepts every metric the schema offers" do
          catalog.datasets.each do |entry|
            names_at(branch(entry.name.to_s), "metric", "enum").each do |metric|
              expect(validator.call(answer(dataset: entry.name.to_s, metric: metric))).to be_ok
            end
          end
        end

        it "accepts every filter the schema offers" do
          catalog.datasets.each do |entry|
            kinds = names_at(branch(entry.name.to_s), "filters", "items", "anyOf")
            kinds.each do |kind|
              kind.dig("properties", "dimension", "enum")&.each do |name|
                expect(validator.call(answer(dataset: entry.name.to_s, filters: [ { "dimension" => name, "op" => "is_null" } ]))).to be_ok
              end
              kind.dig("properties", "segment", "enum")&.each do |name|
                expect(validator.call(answer(dataset: entry.name.to_s, filters: [ { "segment" => name } ]))).to be_ok
              end
            end
          end
        end

        it "accepts every group_by the schema offers, with a granularity where a date needs one" do
          catalog.datasets.each do |entry|
            names_at(branch(entry.name.to_s), "group_by", "items", "properties", "dimension", "enum")&.each do |name|
              item = { "dimension" => name }
              item["granularity"] = "month" if entry.fields.find { |field| field.name.to_s == name }.date?

              expect(validator.call(answer(dataset: entry.name.to_s, group_by: [ item ]))).to be_ok
            end
          end
        end
      end
    end
  end
end
