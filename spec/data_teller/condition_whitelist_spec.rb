require "rails_helper"

RSpec.describe DataTeller::ConditionWhitelist do
  def refused_part(relation, klass: relation.klass, **options)
    described_class.new(klass, **options).refused_part(relation.where_clause.ast)
  end

  let(:orders) { Order.arel_table }
  let(:customers) { Customer.arel_table }

  describe "what a segment is for" do
    {
      "strings in a list" => -> { Customer.where(city: %w[Paris Lyon]) },
      "strings not in a list" => -> { Customer.where.not(city: %w[Paris Lyon]) },
      "a string that looks like SQL" => -> { Customer.where(city: [ "a;b) OR (1=1" ]) },
      "one string" => -> { Customer.where(city: "Paris") },
      "a string compared with Arel" => -> { Customer.where(Customer.arel_table[:city].eq("Paris")) },
      "an enum value" => -> { Order.where(status: :paid) },
      "an association" => -> { Order.where(account: Account.new(id: 1)) },
      "a date range" => -> { Order.where(ordered_at: 1.day.ago..Time.current) },
      "a date" => -> { Order.where(Order.arel_table[:ship_on].lt(Date.current)) },
      "nothing" => -> { Order.all }
    }.each do |label, relation|
      it "accepts #{label}" do
        expect(refused_part(relation.call)).to be_nil
      end
    end

    it "accepts the type condition of a subclass" do
      parent = Class.new(ApplicationRecord) do
        self.table_name = "products"
        self.inheritance_column = "category"
      end
      stub_const("SpecProduct", parent)
      child = Class.new(parent)
      stub_const("SpecBook", child)

      expect(child.all.where_clause).not_to be_empty
      expect(refused_part(child.all)).to be_nil
    end
  end

  describe "what is named in the refusal" do
    it "names the node" do
      expect(refused_part(Order.where(Order.unscoped.arel.exists))).to eq("Arel::Nodes::Exists")
      expect(refused_part(Customer.where(Customer.arel_table[:city].matches("x%")))).to eq("Arel::Nodes::Matches")
      expect(refused_part(Customer.where(Customer.arel_table[:city].lower.eq("x")))).to eq("Arel::Nodes::NamedFunction")
    end

    it "refuses a column missing from the table, a wrong table and an alias" do
      expect(refused_part(Order.where(orders[:nope].eq(1)))).to match(/not a column of orders/)
      expect(refused_part(Order.where(customers[:city].eq("x")))).to match(/not on orders/)
      expect(refused_part(Order.where(orders.alias("x")[:status].eq(1)))).to match(/not on orders/)
      expect(refused_part(Order.where(Arel::Table.new(:orders, as: "o")[:status].eq(1)))).to match(/not on orders/)
    end

    it "refuses a value that is not plain" do
      by_hand = Arel::Nodes::HomogeneousIn.new([ Arel.sql("1) OR (1=1") ], orders[:status], :in)
      expect(described_class.new(Order).refused_part(by_hand)).to match(/not plain/)
      expect(refused_part(Order.where(orders[:status].eq(Arel.sql("1"))))).to eq("Arel::Nodes::SqlLiteral")
      expect(refused_part(Order.where(Arel::Nodes::Equality.new(orders[:status], Arel::Nodes::Quoted.new(Arel.sql("1")))))).to match(/not plain/)
      expect(refused_part(Order.where(id: Order.select(:id)))).to eq("Arel::Nodes::SelectStatement")
    end

    # A subclass of an accepted node can render anything.
    it "compares classes exactly" do
      odd = Class.new(Arel::Nodes::Equality)
      node = odd.new(orders[:status], Arel::Nodes.build_quoted(1))

      expect(described_class.new(Order).refused_part(node)).to eq(odd.to_s)
    end
  end

  describe "raw SQL" do
    it "is refused in a segment" do
      expect(refused_part(Order.where("total_cents > 0"))).to eq("raw SQL")
      expect(refused_part(Order.where("total_cents > ?", 0))).to eq("raw SQL")
    end

    it "is accepted in a default_scope when it cannot end its own parentheses" do
      expect(refused_part(Order.where("ship_on IS NULL"), raw_sql_allowed: true)).to be_nil
      expect(refused_part(Order.where("total_cents > ?", 0), raw_sql_allowed: true)).to be_nil
      expect(refused_part(Order.where("1=1) OR (1=1"), raw_sql_allowed: true)).to match(/escape/)
      expect(refused_part(Order.where("1=1) OR (1=?", 1), raw_sql_allowed: true)).to match(/escape/)
    end

    it "is refused in a default_scope outside of parentheses" do
      node = orders[:status].eq(1).and(Arel.sql("1=1 OR 1=1"))

      expect(described_class.new(Order, raw_sql_allowed: true).refused_part(node)).to match(/without parentheses/)
    end
  end

  # What the compiler relies on: whatever a scope holds stays on its side of the AND.
  describe DataTeller::ScopeInspector do
    let(:model) do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "orders"
        scope :two_conditions, -> { where(status: 1).where(total_cents: 2) }
        scope :an_or, -> { where(status: 1).or(where(status: 2)) }
      end
      stub_const("SpecScoped", klass)
    end

    it "returns the conditions in their own parentheses" do
      [ :two_conditions, :an_or ].each do |name|
        conditions = described_class.conditions(model, name)

        expect(conditions).to be_a(Arel::Nodes::Grouping)
        expect(model.unscoped.where(conditions).where(account_id: 1).to_sql).to match(/WHERE \(.*\) AND "orders"."account_id" = 1\z/)
      end
    end

    it "names the scope and the whitelist in its message" do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "orders"
        scope :a_raw_one, -> { where("total_cents > 0") }
      end
      stub_const("SpecRaw", klass)

      expect { described_class.conditions(klass, :a_raw_one) }.to raise_error(DataTeller::ScopeInspector::Rejected, /a_raw_one holds raw SQL.*compare columns of SpecRaw/)
    end
  end
end
