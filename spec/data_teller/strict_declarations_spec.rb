require "rails_helper"

# A declaration file is trusted code, but these values end up in SQL identifiers and in the LLM schema:
# a typo or a copy-paste must stop at the declaration instead of travelling further.
RSpec.describe "Strict declaration values" do
  error = DataTeller::DeclarationError

  describe DataTeller::Metric do
    def metric(column) = described_class.new(name: :x, aggregation: :sum, column: column)

    it "accepts a column or a belongs_to / has_many path up to depth 2" do
      expect(metric(:total_cents).column).to eq(:total_cents)
      expect(metric("line_items.quantity").column).to eq(:"line_items.quantity")
      expect(metric("customerTotal").column).to eq(:customerTotal)
    end

    [ "total_cents) FROM orders; DROP TABLE orders; --", "lower(email)", "a.b.c.d", "a..b", "", -> { 1 }, 5 ].each do |bad|
      it "rejects #{bad.inspect[0, 30]} as a column" do
        expect { metric(bad) }.to raise_error(error, /column/)
      end
    end

    it "rejects a format that is not a name" do
      expect { described_class.new(name: :x, aggregation: :count, format: 5) }.to raise_error(error, /format/)
    end
  end

  describe DataTeller::Dimension do
    it "accepts an alias to a plain column" do
      expect(described_class.new(name: :shipping_date, column: :ship_on).column).to eq("ship_on")
    end

    # Paths are derived from exposed models, a developer never writes one by hand (ADR 0001 D4).
    [ "customer.city", "lower(email)", "a; drop", -> { 1 } ].each do |bad|
      it "rejects #{bad.inspect[0, 30]} as a column" do
        expect { described_class.new(name: :x, column: bad) }.to raise_error(error, /column/)
      end
    end

    it "accepts only the known types" do
      expect(described_class.new(name: :x, type: "date").type).to eq(:date)
      expect { described_class.new(name: :x, type: :json) }.to raise_error(error, /type/)
      expect { described_class.new(name: :x, type: 5) }.to raise_error(error, /type/)
    end

    %i[time filter sensitive].each do |flag|
      [ "true", "false", 1, nil ].each do |bad|
        it "rejects #{flag}: #{bad.inspect}, which would be silently coerced" do
          expect { described_class.new(name: :x, flag => bad) }.to raise_error(error, /#{flag} must be true or false/)
        end
      end
    end

    it "accepts group: nil as 'decide from the cardinality' but no other non-boolean" do
      expect(described_class.new(name: :x, group: nil).group).to be_nil
      expect { described_class.new(name: :x, group: "yes") }.to raise_error(error, /group must be true, false or nil/)
    end
  end

  describe DataTeller::Segment do
    def segment(**options) = described_class.new(name: :x, **options)

    it "rejects a scope name that is not a name" do
      expect { segment(scope: "destroy_all; x") }.to raise_error(error, /scope/)
      expect { segment(scope: -> { all }) }.to raise_error(error, /scope/)
    end

    it "accepts scalars, lists and nested declarative conditions" do
      where = { status: :paid, total: 10, vip: true, closed_at: nil, kind: %w[a b], created_before: { days_ago: 30 } }
      expect(segment(where: where).where).to eq(where)
    end

    [ "account_id = 1 OR 1=1", false, {}, [ :a ] ].each do |bad|
      it "rejects #{bad.inspect} as a condition" do
        expect { segment(where: bad) }.to raise_error(error, /where: must be a non-empty Hash/)
      end
    end

    it "rejects keys that are not names" do
      expect { segment(where: { 1 => 2 }) }.to raise_error(error, /where: key/)
      expect { segment(where: { "account_id = 1 OR 1" => 1 }) }.to raise_error(error, /where: key/)
    end

    {
      "a date computed at load time" => -> { Date.today },
      "a time computed at load time" => -> { 30.days.ago },
      "a duration" => -> { 30.days },
      "a set hiding a proc" => -> { Set[-> { 1 }] },
      "a callable object" => -> { Object.new.tap { |o| o.define_singleton_method(:call) { 1 } } },
      "a range" => -> { (1..2) }
    }.each do |label, value|
      it "rejects #{label} (data only, resolved by the compiler with the tenant time zone)" do
        expect { segment(where: { ship_on: value.call }) }.to raise_error(error, /data, not code/)
      end
    end

    it "refuses a condition nested in a list" do
      expect { segment(where: { a: [ { days_ago: 30 } ] }) }.to raise_error(error, /a list holds plain values/)
    end

    it "checks nested values too" do
      expect { segment(where: { a: [ Date.today ] }) }.to raise_error(error, /data, not code/)
      expect { segment(where: { a: { b: Date.today } }) }.to raise_error(error, /data, not code/)
    end
  end

  describe "names" do
    it "rejects a name the query schema could never carry" do
      expect { DataTeller::Metric.new(name: "a" * 81, aggregation: :count) }.to raise_error(error, /at most 80/)
      expect(DataTeller::Metric.new(name: "a" * 80, aggregation: :count).name.size).to eq(80)
    end
  end

  describe DataTeller::Dataset do
    it "names the model when a member is declared twice" do
      count = DataTeller::Metric.new(name: :count, aggregation: :count)
      expect { described_class.new(model_name: "Order", metrics: [ count, count ]) }
        .to raise_error(error, /dataset Order: metric :count is declared twice/)
    end
  end
end
