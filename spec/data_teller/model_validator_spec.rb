require "rails_helper"

# Everything here reads the code of the models, so it can run at boot (ADR 0004 D6).
RSpec.describe DataTeller::ModelValidator do
  before(:all) do
    # Spec-only model: situations the dummy app's clean domain does not have.
    Object.const_set(:SpecRecord, Class.new(ApplicationRecord))
    SpecRecord.class_eval do
      self.table_name = "orders"

      belongs_to :owner, polymorphic: true, optional: true
      belongs_to :owner_product, class_name: "Product", foreign_key: :owner_id, optional: true # owner_type never checked
      belongs_to :ghost, class_name: "NoSuchModel", optional: true
      belongs_to :customer, optional: true
      belongs_to :billing_customer, class_name: "Customer", optional: true

      scope :real_scope, -> { where(status: 1) }
      def self.purge_all = nil
    end
  end

  after(:all) { Object.send(:remove_const, :SpecRecord) }

  let(:config) do
    DataTeller::Configuration.new.tap do |c|
      c.tenant do
        model Account
        resolve { |user| user.account }
      end
      c.expose "Order", "Customer", "LineItem", "Product", "SpecRecord", "Account"
    end
  end
  let(:registry) { DataTeller::Registry.new }

  def errors_for(model, tenant_path, **parts)
    registry.register(DataTeller::Dataset.new(model_name: model, roles: [ :admin ], tenant_path: tenant_path, **parts))
    described_class.new(config: config, registry: registry).call
  end

  def metric(name, column, aggregation = :sum, **options)
    DataTeller::Metric.new(name: name, aggregation: aggregation, column: column, **options)
  end

  def scope_segment(name) = DataTeller::Segment.new(name: :x, scope: name, roles: :admin)

  describe "models" do
    it "refuses a dataset whose model does not exist" do
      expect(errors_for("Quote", %i[account])).to contain_exactly(/dataset quotes: model Quote is not an ActiveRecord model/)
    end

    it "refuses a tenant model that does not exist" do
      config.tenant { model "Tenantt"; resolve { |u| u } }

      expect(errors_for("Order", %i[account])).to contain_exactly(/tenant: model Tenantt is not an ActiveRecord model/)
    end
  end

  describe "tenant_path" do
    it "accepts a direct belongs_to" do
      expect(errors_for("Order", %i[account])).to eq([])
    end

    it "accepts a longer path" do
      expect(errors_for("LineItem", %i[order account])).to eq([])
    end

    it "accepts either of two valid paths: choosing is the developer's call, in a visible line" do
      expect(errors_for("Order", %i[customer account])).to eq([])
    end

    it "is mandatory" do
      expect(errors_for("Order", nil)).to contain_exactly(/dataset orders: tenant_path is required.*tenant_path :/)
    end

    it "is not needed on the tenant model itself" do
      expect(errors_for("Account", nil)).to eq([])
    end

    it "is refused on the tenant model itself" do
      expect(errors_for("Account", %i[orders])).to contain_exactly(/dataset accounts: .*tenant model.*no tenant_path/)
    end

    it "refuses an unknown association, naming the model where the walk stopped" do
      expect(errors_for("LineItem", %i[order nope])).to contain_exactly(/line_items: tenant_path: Order has no association :nope/)
    end

    it "refuses a has_many, which would multiply rows and does not identify one tenant" do
      expect(errors_for("Customer", %i[orders account])).to contain_exactly(/customers: tenant_path: Customer\.orders is a has_many, only belongs_to/)
    end

    it "refuses a polymorphic belongs_to, whose target is only known per row" do
      expect(errors_for("SpecRecord", %i[owner])).to contain_exactly(/tenant_path: SpecRecord\.owner is polymorphic/)
    end

    # The workaround the refusal above invites: an owner of type Customer with id 5 would pass for Product 5, another tenant's.
    it "refuses a belongs_to on a polymorphic key, which reads the id without its type" do
      expect(errors_for("SpecRecord", %i[owner_product account]))
        .to contain_exactly(/tenant_path: SpecRecord\.owner_product reads owner_id, the key of a polymorphic association, without its type/)
    end

    it "refuses an association whose class is missing" do
      expect(errors_for("SpecRecord", %i[ghost])).to contain_exactly(/tenant_path: SpecRecord\.ghost points to NoSuchModel, which does not exist/)
    end

    it "refuses a path that ends somewhere else" do
      expect(errors_for("LineItem", %i[order customer])).to contain_exactly(/line_items: tenant_path ends at Customer, not at Account/)
    end
  end

  describe "metric paths (ADR 0001 D4)" do
    it "accepts a path to an exposed model" do
      expect(errors_for("Order", %i[account], metrics: [ metric(:items, "line_items.quantity") ])).to eq([])
    end

    it "refuses a path to a model that is not exposed, which would have no tenant_path" do
      config.instance_variable_set(:@exposed_models, %w[Order])

      expect(errors_for("Order", %i[account], metrics: [ metric(:items, "line_items.quantity") ]))
        .to contain_exactly(/metric items: the path reaches LineItem, which is not exposed/)
    end

    it "refuses an unknown association" do
      expect(errors_for("Order", %i[account], metrics: [ metric(:x, "nope.quantity") ]))
        .to contain_exactly(/metric x: Order has no association :nope/)
    end

    it "cannot be divided in a ratio: the join would change what the other side counts" do
      metrics = [ metric(:items, "line_items.quantity"), DataTeller::Metric.new(name: :count, aggregation: :count),
                  DataTeller::Metric.new(name: :per_order, aggregation: :ratio, of: %i[items count]) ]

      expect(errors_for("Order", %i[account], metrics: metrics)).to contain_exactly(/metric per_order: a ratio cannot use items/)
    end

    it "refuses a has_many through: the table in the middle would have no tenant filter" do
      Order.has_many(:spec_products_through, through: :line_items, source: :product)

      expect(errors_for("Order", %i[account], metrics: [ metric(:x, "spec_products_through.price_cents") ]))
        .to contain_exactly(/metric x: Order\.spec_products_through goes through another table/)
    ensure
      Order._reflections.delete("spec_products_through")
    end

    it "refuses a has_many on a polymorphic key without `as:`, and accepts it with" do
      Product.has_many(:spec_records_by_key, class_name: "SpecRecord", foreign_key: :owner_id)
      Product.has_many(:spec_records_typed, class_name: "SpecRecord", as: :owner)

      expect(errors_for("Product", %i[account], metrics: [ metric(:x, "spec_records_by_key.total_cents"), metric(:y, "spec_records_typed.total_cents") ]))
        .to contain_exactly(/metric x: Product\.spec_records_by_key reads owner_id, the key of a polymorphic association/)
    ensure
      Product._reflections.delete("spec_records_by_key")
      Product._reflections.delete("spec_records_typed")
    end

    # Its join table has no model, so no tenant_path: it would be joined with no tenant filter, and Rails does not call it a through.
    it "refuses a has_and_belongs_to_many for the same reason" do
      Order.has_and_belongs_to_many(:spec_products_habtm, class_name: "Product", join_table: "line_items")

      expect(errors_for("Order", %i[account], metrics: [ metric(:x, "spec_products_habtm.price_cents") ]))
        .to contain_exactly(/metric x: Order\.spec_products_habtm goes through another table/)
    ensure
      Order._reflections.delete("spec_products_habtm")
    end

    it "refuses a path that comes back to a table it already went through" do
      expect(errors_for("Order", %i[account], metrics: [ metric(:x, "customer.orders.total_cents") ]))
        .to contain_exactly(/metric x: Customer\.orders comes back to the table orders/)
    end

    it "refuses a sum or a minimum on an enum" do
      expect(errors_for("Order", %i[account], metrics: [ metric(:x, :status, :min), metric(:y, :status, :sum), metric(:z, :status, :count_distinct) ]))
        .to contain_exactly(/metric x: min means nothing on the enum status/, /metric y: sum means nothing on the enum status/)
    end

    it "refuses a polymorphic association" do
      expect(errors_for("SpecRecord", %i[customer], metrics: [ metric(:x, "owner.total") ]))
        .to include(/metric x: SpecRecord\.owner is polymorphic/)
    end
  end

  # The unit is counted on the dataset's own table (ADR 0012 D1).
  describe "min_group_size of:" do
    def errors_with_unit(model, unit) = errors_for(model, %i[account], min_group_size: DataTeller::MinGroupSize.new(minimum: 5, of: unit))

    it "accepts a direct belongs_to" do
      expect(errors_with_unit("Order", :customer)).to eq([])
    end

    it "refuses an unknown association and a has_many" do
      expect(errors_with_unit("Order", :nope)).to contain_exactly(/dataset orders: min_group_size of: Order has no association :nope/)
      expect(errors_with_unit("Customer", :orders)).to include(/min_group_size of: Customer\.orders is a has_many, the unit must be a belongs_to/)
    end

    it "refuses a polymorphic belongs_to" do
      expect(errors_for("SpecRecord", %i[customer account], min_group_size: DataTeller::MinGroupSize.new(minimum: 5, of: :owner)))
        .to include(/min_group_size of: SpecRecord\.owner is polymorphic/)
    end

    # It would count a customer and a product with the same id as one person.
    it "refuses a polymorphic key read without its type" do
      expect(errors_for("SpecRecord", %i[customer account], min_group_size: DataTeller::MinGroupSize.new(minimum: 5, of: :owner_product)))
        .to include(/min_group_size of: SpecRecord\.owner_product reads owner_id, the key of a polymorphic association/)
    end
  end

  describe "two paths to the same dataset (ADR 0001 D4)" do
    it "are refused, the LLM could not tell them apart" do
      registry.register(DataTeller::Dataset.new(model_name: "Customer", roles: [ :admin ], tenant_path: %i[account],
                                                dimensions: [ DataTeller::Dimension.new(name: :city) ]))

      expect(errors_for("SpecRecord", %i[customer account]))
        .to include(/dataset spec_records: customer and billing_customer both lead to Customer/)
    end

    it "keep the shortest one, and are fine then" do
      registry.register(DataTeller::Dataset.new(model_name: "Customer", roles: [ :admin ], tenant_path: %i[account],
                                                dimensions: [ DataTeller::Dimension.new(name: :city) ]))
      registry.register(DataTeller::Dataset.new(model_name: "Subscription", roles: [ :admin ], tenant_path: %i[account]))
      invoices = DataTeller::Dataset.new(model_name: "Invoice", roles: [ :admin ], tenant_path: %i[account])
      registry.register(invoices)

      hops = DataTeller::DimensionPaths.hops(invoices, registry: registry, tenant_model_name: "Account")

      expect(hops.map(&:prefix)).to contain_exactly("customer", "subscription")
      expect(DataTeller::DimensionPaths.shadowed(invoices, registry: registry, tenant_model_name: "Account").map { |left, kept| [ left.prefix, kept.prefix ] })
        .to eq([ %w[subscription.customer customer] ])
      expect(described_class.new(config: config, registry: registry).call.grep(/both lead/)).to eq([])
    end

    it "never go through a polymorphic key read without its type" do
      registry.register(DataTeller::Dataset.new(model_name: "Product", roles: [ :admin ], tenant_path: %i[account]))
      records = DataTeller::Dataset.new(model_name: "SpecRecord", roles: [ :admin ], tenant_path: %i[account])

      expect(DataTeller::DimensionPaths.hops(records, registry: registry, tenant_model_name: "Account").map(&:prefix)).not_to include("owner_product")
    end

    it "are fine when the target is not exposed" do
      expect(errors_for("SpecRecord", %i[customer account]).grep(/both lead/)).to eq([])
    end
  end

  describe "scope: segments" do
    it "accepts a scope declared with `scope`" do
      expect(errors_for("SpecRecord", %i[customer], segments: [ scope_segment(:real_scope) ]).grep(/segment/)).to eq([])
    end

    it "accepts an enum scope" do
      expect(errors_for("Order", %i[account], segments: [ scope_segment(:paid) ])).to eq([])
    end

    it "refuses a name the model does not have" do
      expect(errors_for("Order", %i[account], segments: [ scope_segment(:nope) ]))
        .to contain_exactly(/segment x: Order has no scope :nope/)
    end

    # Such a method could do anything, and `rake data_teller:check` calls scopes to inspect them.
    it "refuses a class method, even one that looks harmless" do
      expect(errors_for("SpecRecord", %i[customer], segments: [ scope_segment(:purge_all) ]).grep(/segment/))
        .to contain_exactly(/segment x: SpecRecord has no scope :purge_all/)
    end

    # Rails records a class method in its list of relation methods once it is called on a relation.
    it "still refuses a class method after it was called on a relation" do
      SpecRecord.where(status: 1).purge_all

      expect(errors_for("SpecRecord", %i[customer], segments: [ scope_segment(:purge_all) ]).grep(/segment/))
        .to contain_exactly(/segment x: SpecRecord has no scope :purge_all/)
    end

    it "accepts a scope inherited from an abstract parent" do
      parent = Class.new(ApplicationRecord) { self.abstract_class = true }
      stub_const("SpecAbstract", parent)
      parent.scope :inherited_one, -> { where(status: 1) }
      child = Class.new(parent) { self.table_name = "orders" }
      stub_const("SpecChild", child)

      expect(DataTeller::ModelLookup.declared_scope?(SpecChild, :inherited_one)).to be(true)
    end

    it "leaves built-in methods to the declaration lint, which has a clearer message" do
      expect(errors_for("Order", %i[account], segments: [ scope_segment(:destroy_all) ])).to eq([])
    end
  end
end
