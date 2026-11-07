require "rails_helper"

RSpec.describe DataTeller::Catalog do
  def dataset(model, roles: %i[admin support], tenant_path: %i[account], **parts)
    DataTeller::Dataset.new(model_name: model, roles: roles, tenant_path: tenant_path, **parts)
  end

  def metric(name, aggregation = :count, **options) = DataTeller::Metric.new(name: name, aggregation: aggregation, **options)
  def dimension(name, **options) = DataTeller::Dimension.new(name: name, **options)
  def segment(name, **options) = DataTeller::Segment.new(name: name, **options)

  def catalog(*roles, datasets:)
    registry = DataTeller::Registry.new
    datasets.each { |d| registry.register(d) }
    described_class.new(roles, registry: registry.freeze!, tenant_model_name: "Account")
  end

  describe "the dummy app" do
    let(:admin) { described_class.for(:admin) }
    let(:support) { described_class.for(:support) }

    it "shows admin everything" do
      expect(admin.dataset(:orders).metrics.map(&:name)).to contain_exactly(:count, :revenue, :net_revenue, :discounts, :avg_basket, :customers)
    end

    it "hides revenue from support, and the ratio that would reveal it" do
      expect(support.dataset(:orders).metrics.map(&:name)).to contain_exactly(:count, :customers)
    end

    it "derives paths from the exposed models" do
      expect(admin.dataset(:orders).fields.map(&:name)).to include(:status, :"customer.city", :"customer.name")
      expect(admin.dataset(:customers).fields.map(&:name)).to contain_exactly(:city, :name, :acquisition_channel, :tier, :signed_up_on)
    end
  end

  describe "who sees what" do
    it "shows nothing without a role" do
      expect(catalog(datasets: [ dataset("Order") ]).datasets).to be_empty
    end

    it "gives an unknown role no permission" do
      expect(catalog(:intern, datasets: [ dataset("Order") ]).datasets).to be_empty
    end

    it "hides a dataset from the roles it does not list" do
      expect(catalog(:support, datasets: [ dataset("Order", roles: %i[admin]) ]).datasets).to be_empty
    end

    it "lets members narrow the roles" do
      parts = { metrics: [ metric(:count, roles: :admin) ], dimensions: [ dimension(:status, roles: :admin) ],
                segments: [ segment(:paid, where: { total_cents: 1 }, roles: :admin) ] }
      visible = catalog(:support, datasets: [ dataset("Order", **parts) ]).dataset(:orders)

      expect(visible.metrics).to be_empty
      expect(visible.fields).to be_empty
      expect(visible.segments).to be_empty
    end

    it "takes the union of several roles" do
      parts = { metrics: [ metric(:a, roles: :admin), metric(:b, roles: :support) ] }

      expect(catalog(:admin, :support, datasets: [ dataset("Order", **parts) ]).dataset(:orders).metrics.map(&:name)).to contain_exactly(:a, :b)
    end

    it "accepts role names as strings" do
      expect(catalog("admin", datasets: [ dataset("Order") ]).datasets.map(&:name)).to eq([ :orders ])
    end
  end

  describe "derived metrics (ADR 0004 D5)" do
    let(:metrics) do
      [ metric(:count), metric(:revenue, :sum, column: :total_cents, roles: :admin),
        metric(:basket, :ratio, of: %i[revenue count]), metric(:basket_per_order, :ratio, of: %i[basket count]) ]
    end

    it "hides a ratio whose dependency is hidden, through several levels" do
      expect(catalog(:support, datasets: [ dataset("Order", metrics: metrics) ]).dataset(:orders).metrics.map(&:name)).to eq([ :count ])
    end

    it "uses the union: each role can bring one dependency" do
      parts = [ metric(:a, roles: :admin), metric(:b, roles: :support), metric(:ratio, :ratio, of: %i[a b]) ]

      expect(catalog(:admin, :support, datasets: [ dataset("Order", metrics: parts) ]).dataset(:orders).metrics.map(&:name)).to include(:ratio)
      expect(catalog(:admin, datasets: [ dataset("Order", metrics: parts) ]).dataset(:orders).metrics.map(&:name)).not_to include(:ratio)
    end
  end

  # ADR 0004 D5: a permission applies to every use of a column.
  describe "metrics over a hidden column" do
    it "are hidden with it" do
      parts = { metrics: [ metric(:top, :max, column: :total_cents) ], dimensions: [ dimension(:total_cents, roles: :admin) ] }

      expect(catalog(:support, datasets: [ dataset("Order", **parts) ]).dataset(:orders).metrics).to be_empty
      expect(catalog(:admin, datasets: [ dataset("Order", **parts) ]).dataset(:orders).metrics.map(&:name)).to eq([ :top ])
    end

    it "match by column, not by name" do
      parts = { metrics: [ metric(:top, :max, column: :total_cents) ], dimensions: [ dimension(:amount, column: :total_cents, roles: :admin) ] }

      expect(catalog(:support, datasets: [ dataset("Order", **parts) ]).dataset(:orders).metrics).to be_empty
    end

    it "are hidden when the column is on the table a path reaches" do
      orders = dataset("Order", metrics: [ metric(:items, :sum, column: "line_items.quantity") ])
      items = dataset("LineItem", tenant_path: %i[order account], dimensions: [ dimension(:quantity, roles: :admin) ])

      expect(catalog(:support, datasets: [ orders, items ]).dataset(:orders).metrics).to be_empty
    end
  end

  describe "metrics over another table" do
    let(:parts) { { metrics: [ metric(:items, :sum, column: "line_items.quantity") ] } }

    it "are visible only if that table's dataset is" do
      items = dataset("LineItem", roles: %i[admin], tenant_path: %i[order account])

      expect(catalog(:support, datasets: [ dataset("Order", **parts), items ]).dataset(:orders).metrics).to be_empty
      expect(catalog(:admin, datasets: [ dataset("Order", **parts), items ]).dataset(:orders).metrics.map(&:name)).to eq([ :items ])
    end
  end

  describe "segments (ADR 0004 D5)" do
    let(:parts) do
      { dimensions: [ dimension(:status, roles: :admin) ], segments: [ segment(:paid, where: { status: :paid }), segment(:big, where: { total_cents: 1 }) ] }
    end

    it "hides a segment that references a hidden dimension: it would reveal its values" do
      expect(catalog(:support, datasets: [ dataset("Order", **parts) ]).dataset(:orders).segments.map(&:name)).to eq([ :big ])
    end

    it "matches by column, not only by name" do
      aliased = { dimensions: [ dimension(:state, column: :status, roles: :admin) ], segments: [ segment(:paid, where: { status: :paid }) ] }

      expect(catalog(:support, datasets: [ dataset("Order", **aliased) ]).dataset(:orders).segments).to be_empty
    end
  end

  describe "paths (ADR 0001 D4)" do
    let(:customers) { dataset("Customer", dimensions: [ dimension(:city), dimension(:name, roles: :admin) ]) }
    let(:orders) { dataset("Order", dimensions: [ dimension(:status) ]) }

    def fields_of(*roles, datasets:) = catalog(*roles, datasets: datasets).dataset(:orders).fields.map(&:name)

    it "needs the target model to be exposed" do
      expect(fields_of(:admin, datasets: [ orders ])).to eq([ :status ])
    end

    it "inherits the permissions of the target dimension, not only those of the starting dataset" do
      expect(fields_of(:support, datasets: [ orders, customers ])).to contain_exactly(:status, :"customer.city")
    end

    it "inherits the permissions of the target dataset" do
      hidden = dataset("Customer", roles: %i[admin], dimensions: [ dimension(:city) ])

      expect(fields_of(:support, datasets: [ orders, hidden ])).to eq([ :status ])
    end

    # order.customer.city would otherwise reveal which customers placed orders, to a role that cannot see orders.
    it "needs every dataset on the way to be visible, not only the last one" do
      items = dataset("LineItem", tenant_path: %i[order account], dimensions: [ dimension(:quantity) ])
      hidden_orders = dataset("Order", roles: %i[admin], dimensions: [ dimension(:status) ])

      expect(catalog(:support, datasets: [ items, hidden_orders, customers ]).dataset(:line_items).fields.map(&:name)).to eq([ :quantity ])
    end

    it "never exposes a column that is not declared on its own model" do
      expect(fields_of(:admin, datasets: [ orders, customers ])).not_to include(:"customer.email")
    end

    it "goes through belongs_to only" do
      visible = catalog(:admin, datasets: [ orders, customers ]).dataset(:customers).fields.map(&:name)

      expect(visible.grep(/orders\./)).to be_empty
    end

    it "does not go through the tenant model, where every row has the same value" do
      account = dataset("Account", tenant_path: nil, dimensions: [ dimension(:name) ])

      expect(fields_of(:admin, datasets: [ orders, account ])).to eq([ :status ])
    end

    it "goes up to depth 2" do
      items = dataset("LineItem", dimensions: [ dimension(:quantity) ], tenant_path: %i[order account])

      expect(catalog(:admin, datasets: [ items, orders, customers ]).dataset(:line_items).fields.map(&:name))
        .to contain_exactly(:quantity, :"order.status", :"order.customer.city", :"order.customer.name")
    end
  end
end
