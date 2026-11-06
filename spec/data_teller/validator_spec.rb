require "rails_helper"

RSpec.describe DataTeller::Validator do
  let(:config) do
    DataTeller::Configuration.new.tap do |c|
      c.tenant { |user| user.account }
      c.expose "Order"
    end
  end
  let(:registry) { DataTeller::Registry.new }

  def dataset(model: "Order", roles: %i[admin support], **parts)
    registry.register(DataTeller::Dataset.new(model_name: model, roles: roles, **parts))
  end

  def metric(name, aggregation = :count, **options) = DataTeller::Metric.new(name: name, aggregation: aggregation, **options)
  def dimension(name, **options) = DataTeller::Dimension.new(name: name, **options)

  subject(:report) { described_class.new(config: config, registry: registry).call }

  it "accepts a valid configuration" do
    dataset(metrics: [ metric(:count) ], dimensions: [ dimension(:status) ])

    expect(report).to be_ok
  end

  it "accepts the dummy app declarations" do
    DataTeller::Loader.load!(Rails.root)

    expect(described_class.new.call.errors).to eq([])
  end

  it "requires a tenant resolver" do
    dataset
    config.instance_variable_set(:@tenant_resolver, nil)

    expect(report.errors).to include(/no tenant resolver/)
  end

  it "requires roles on every dataset" do
    dataset(roles: nil)

    expect(report.errors).to include(/dataset orders: roles are required/)
  end

  it "makes exposure and refinement agree in both directions" do
    config.expose "Customer"
    dataset(model: "Product")

    expect(report.errors).to include(
      /Order is exposed but has no .*refine Order/,
      /Customer is exposed but has no/,
      /Product is refined but not listed/
    )
  end

  it "allows a single default time dimension" do
    dataset(dimensions: [ dimension(:ordered_at, time: true), dimension(:ship_on, time: true) ])

    expect(report.errors).to include(/only one default time dimension.*ordered_at, ship_on/)
  end

  describe "sensitive dimensions" do
    it "refuses a sensitive-looking name unless it is forced with sensitive: true" do
      dataset(dimensions: [ dimension(:email), dimension(:customer_phone, column: "customer.phone"), dimension(:monkey) ])

      expect(report.errors.grep(/looks sensitive/).size).to eq(2)
    end

    it "requires explicit roles once forced" do
      dataset(dimensions: [ dimension(:email, sensitive: true) ])
      expect(report.errors).to include(/sensitive dimension needs explicit `roles:`/)

      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin],
                                                dimensions: [ dimension(:email, sensitive: true, roles: :admin) ]))
      expect(described_class.new(config: config, registry: registry).call).to be_ok
    end
  end

  it "requires explicit roles on a scope segment" do
    dataset(segments: [ DataTeller::Segment.new(name: :vip, scope: :vip_customers) ])

    expect(report.errors).to include(/segment vip: a `scope:` segment needs explicit `roles:`/)
  end

  describe "derived metrics" do
    it "refuses a ratio of an unknown metric" do
      dataset(metrics: [ metric(:avg_basket, :ratio, of: %i[revenue count]) ])

      expect(report.errors).to include(/avg_basket: ratio refers to unknown metric revenue/)
    end

    it "refuses cycles" do
      dataset(metrics: [ metric(:a, :ratio, of: %i[b count]), metric(:b, :ratio, of: %i[a count]) ])

      expect(report.errors).to include(/form a cycle \(a -> b -> a\)/)
    end

    it "accepts a ratio of a ratio that is not circular" do
      dataset(metrics: [ metric(:count), metric(:revenue, :sum, column: :total), metric(:basket, :ratio, of: %i[revenue count]),
                         metric(:basket_per_unit, :ratio, of: %i[basket count]) ])

      expect(report).to be_ok
    end
  end

  describe "role narrowing" do
    it "refuses a member that widens the dataset's roles" do
      dataset(metrics: [ metric(:revenue, :sum, column: :total, roles: %i[admin billing]) ])

      expect(report.errors).to include(/metric revenue: roles \[:billing\] are not in the dataset's roles/)
    end

    it "accepts a member that narrows them" do
      dataset(metrics: [ metric(:revenue, :sum, column: :total, roles: :admin) ])

      expect(report).to be_ok
    end
  end

  it "reports every problem at once" do
    config.instance_variable_set(:@tenant_resolver, nil)
    dataset(roles: nil, dimensions: [ dimension(:email) ])

    expect(report.errors.size).to be >= 3
    expect(report.message).to start_with("DataTeller configuration is invalid (").and include("no tenant resolver")
  end
end
