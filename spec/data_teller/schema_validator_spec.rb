require "rails_helper"

# Reads the database, so it only runs in `rake data_teller:check`, never at boot (ADR 0004 D6).
RSpec.describe DataTeller::SchemaValidator do
  before(:all) do
    # Spec-only model: scopes the dummy app's clean domain does not have.
    Object.const_set(:SpecScopes, Class.new(ApplicationRecord))
    SpecScopes.class_eval do
      self.table_name = "orders"

      scope :fine, -> { where(status: 1) }
      scope :needs_argument, ->(date) { where(ship_on: date) }
      scope :ordered, -> { order(:id) }
      scope :limited, -> { limit(1) }
      scope :grouped, -> { group(:status) }
      scope :selected, -> { select(:id) }
      scope :writes, -> { update_all(status: 4) && all }
      scope :not_a_relation, -> { 42 }
    end
  end

  after(:all) { Object.send(:remove_const, :SpecScopes) }

  let(:registry) { DataTeller::Registry.new }

  def errors_for(model = "Order", **parts)
    registry.register(DataTeller::Dataset.new(model_name: model, roles: [ :admin ], tenant_path: %i[account], **parts))
    described_class.new(registry: registry).call
  end

  def metric(name, aggregation, column) = DataTeller::Metric.new(name: name, aggregation: aggregation, column: column)
  def dimension(name, **options) = DataTeller::Dimension.new(name: name, **options)
  def segment(**options) = DataTeller::Segment.new(name: :x, roles: :admin, **options)

  it "accepts the dummy app" do
    expect(described_class.new(registry: DataTeller.registry).call).to eq([])
  end

  describe "tables" do
    it "refuses a model whose table is missing" do
      Object.const_set(:SpecNoTable, Class.new(ApplicationRecord) { self.table_name = "no_such_table" })

      expect(errors_for("SpecNoTable", dimensions: [ dimension(:x) ])).to contain_exactly(/dataset spec_no_tables: table no_such_table does not exist/)
    ensure
      Object.send(:remove_const, :SpecNoTable)
    end
  end

  describe "dimensions" do
    it "accepts an existing column, aliased or not" do
      expect(errors_for(dimensions: [ dimension(:status), dimension(:shipping, column: :ship_on) ])).to eq([])
    end

    it "refuses a column that does not exist" do
      expect(errors_for(dimensions: [ dimension(:nope) ])).to contain_exactly(/dataset orders, dimension nope: Order has no column nope/)
    end

    it "requires a date or datetime for the time dimension" do
      expect(errors_for(dimensions: [ dimension(:status, time: true) ]))
        .to contain_exactly(/dimension status: `time: true` needs a date or datetime column, status is integer/)
      expect(DataTeller::Registry.new.then { |r|
        r.register(DataTeller::Dataset.new(model_name: "Order", dimensions: [ dimension(:ordered_at, time: true) ]))
        described_class.new(registry: r).call
      }).to eq([])
    end

    it "requires a text column for a lookup" do
      expect(errors_for(dimensions: [ dimension(:total_cents, lookup: :trigram) ]))
        .to contain_exactly(/dimension total_cents: `lookup:` needs a text column, total_cents is integer/)
    end
  end

  describe "metrics" do
    it "accepts numbers for sum and avg, numbers and dates for min and max, anything for count_distinct" do
      expect(errors_for(metrics: [
        metric(:a, :sum, :total_cents), metric(:b, :avg, :total_cents), metric(:c, :min, :total_cents),
        metric(:d, :max, :ordered_at), metric(:e, :count_distinct, :customer_id), metric(:f, :sum, "line_items.quantity")
      ])).to eq([])
    end

    it "refuses a column that does not exist, on the model the path reaches" do
      expect(errors_for(metrics: [ metric(:a, :sum, :nope), metric(:b, :sum, "line_items.nope") ]))
        .to contain_exactly(/metric a: Order has no column nope/, /metric b: LineItem has no column nope/)
    end

    # On a string column, min and max return a stored value: row-level disclosure presented as an aggregate.
    it "refuses min and max on a text column" do
      expect(errors_for("Customer", metrics: [ metric(:first_name, :min, :name) ]))
        .to contain_exactly(/metric first_name: min returns a stored value, it needs a number or a date, name is string/)
    end

    it "refuses sum and avg on anything but a number" do
      expect(errors_for(metrics: [ metric(:a, :sum, :ordered_at) ]))
        .to contain_exactly(/metric a: sum needs a number, ordered_at is datetime/)
    end

    it "skips a path the model validator has already reported" do
      expect(errors_for(metrics: [ metric(:a, :sum, "nope.total") ])).to eq([])
    end
  end

  describe "where: segments" do
    it "accepts existing columns" do
      expect(errors_for(segments: [ segment(where: { status: :paid }) ])).to eq([])
    end

    it "refuses a column that does not exist" do
      expect(errors_for(segments: [ segment(where: { nope: 1 }) ])).to contain_exactly(/segment x: Order has no column nope/)
    end

    it "leaves a declarative condition to the compiler" do
      expect(errors_for(segments: [ segment(where: { created_before: { days_ago: 30 } }) ])).to eq([])
    end
  end

  describe "scope: segments (ADR 0004 D4)" do
    def scope_errors(name)
      errors_for("SpecScopes", segments: [ segment(scope: name) ])
    end

    it "accepts a scope that only adds conditions" do
      expect(scope_errors(:fine)).to eq([])
    end

    it "refuses a scope that needs an argument" do
      expect(scope_errors(:needs_argument)).to contain_exactly(/segment x: scope :needs_argument takes an argument/)
    end

    { ordered: "order", limited: "limit", grouped: "group", selected: "select" }.each do |name, clause|
      it "refuses a scope with #{clause}, which would change the result of an aggregate" do
        expect(scope_errors(name)).to contain_exactly(/segment x: scope :#{name} uses #{clause}/)
      end
    end

    it "refuses a scope that does not return a relation" do
      expect(scope_errors(:not_a_relation)).to contain_exactly(/segment x: scope :not_a_relation/)
    end

    it "reports a scope that writes while being inspected, without letting it write" do
      account = Account.create!(name: "Spec", time_zone: "UTC")
      customer = account.customers.create!(name: "Spec", email: "spec@example.test")
      order = account.orders.create!(customer: customer, status: :paid, total_cents: 1, ordered_at: Time.current)

      expect(scope_errors(:writes)).to contain_exactly(/segment x: scope :writes failed when called, it may be trying to write/)
      expect(order.reload.status).to eq("paid")
    ensure
      order&.destroy
      customer&.destroy
      account&.destroy
    end

    it "leaves names that are not declared scopes to the model validator, without calling them" do
      expect(Order).not_to receive(:destroy_all)
      expect(errors_for(segments: [ segment(scope: :destroy_all) ])).to eq([])
    end
  end

  it "reports an unreachable database as one problem" do
    allow(Order).to receive(:table_exists?).and_raise(ActiveRecord::ConnectionNotEstablished, "no route")

    expect(errors_for(dimensions: [ dimension(:status) ])).to contain_exactly(/cannot read the database.*ConnectionNotEstablished/)
  end
end
