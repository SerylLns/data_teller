require "rails_helper"

RSpec.describe DataTeller::Validator do
  let(:config) do
    DataTeller::Configuration.new.tap do |c|
      c.tenant do
        model Account
        resolve { |user| user.account }
      end
      c.expose "Order"
    end
  end
  let(:registry) { DataTeller::Registry.new }

  def dataset(model: "Order", roles: %i[admin support], **parts)
    registry.register(DataTeller::Dataset.new(model_name: model, roles: roles, tenant_path: %i[account], **parts))
  end

  def metric(name, aggregation = :count, **options) = DataTeller::Metric.new(name: name, aggregation: aggregation, **options)
  def dimension(name, **options) = DataTeller::Dimension.new(name: name, **options)

  subject(:report) { described_class.new(config: config, registry: registry).call }

  it "accepts a valid configuration" do
    dataset(metrics: [ metric(:count) ], dimensions: [ dimension(:status) ])

    expect(report).to be_ok
  end

  it "accepts the dummy app declarations" do
    expect(DataTeller.check(Rails.root).errors).to eq([])
  end

  it "requires a tenant resolver" do
    dataset
    config.instance_variable_set(:@tenant, nil)

    expect(report.errors).to include(/no tenant:/)
  end

  it "refuses row_security without the database role its policies apply to" do
    dataset(metrics: [ metric(:count) ])
    config.row_security = true
    expect(report.errors).to include(/row_security needs database_role/)

    config.database_role = "data_teller_reader"
    expect(described_class.new(config: config, registry: registry).call).to be_ok
  end

  it "requires both the model and the resolver of the tenant" do
    dataset
    config.instance_variable_set(:@tenant, nil)
    config.tenant { resolve { |user| user.account } }
    expect(described_class.new(config: config, registry: registry).call.errors).to include(/tenant: `model` is missing/)

    config.tenant { model Account }
    expect(described_class.new(config: config, registry: registry).call.errors).to include(/tenant: `resolve` is missing/)
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
      dataset(dimensions: [ dimension(:email), dimension(:contact, column: "phone"), dimension(:monkey) ])

      expect(report.errors.grep(/looks sensitive/).size).to eq(2)
    end

    it "requires explicit roles once forced" do
      dataset(dimensions: [ dimension(:email, sensitive: true) ])
      expect(report.errors).to include(/sensitive dimension needs explicit `roles:`/)

      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                dimensions: [ dimension(:email, sensitive: true, roles: :admin) ]))
      expect(described_class.new(config: config, registry: registry).call).to be_ok
    end
  end

  describe "columns the host app already treats as sensitive" do
    # The word lists do not know "phone_hash", the host's filter_parameters may.
    around do |example|
      previous = ActiveRecord::Base.filter_attributes
      ActiveRecord::Base.filter_attributes += [ :nickname ]
      example.run
    ensure
      ActiveRecord::Base.filter_attributes = previous
    end

    it "are caught on dimensions, through filter_attributes" do
      dataset(dimensions: [ dimension(:other, column: "nickname") ])

      expect(report.errors).to include(/dimension other: .*looks sensitive/)
    end

    it "are caught on metrics, on the model the path reaches" do
      dataset(metrics: [ metric(:x, :max, column: "customer.nickname") ])

      expect(report.errors).to include(/metric x: .*looks sensitive/)
    end

    it "are caught when encrypted" do
      allow(Order).to receive(:encrypted_attributes).and_return(Set[:private_note])
      dataset(dimensions: [ dimension(:other, column: "private_note") ])

      expect(report.errors).to include(/dimension other: .*looks sensitive/)
    end
  end

  describe "sensitive-looking names" do
    %w[api_key access_key private_key emails e_mail tokens passwords phones secrets credit_card card_number
       customerEmail EMAIL password_digest encrypted_notes date_of_birth ip_address].each do |column|
      it "catches #{column}" do
        dataset(dimensions: [ dimension(:contact, column: column) ])

        expect(report.errors).to include(/looks sensitive/)
      end
    end

    %w[monkey keyboard status city mailbox].each do |column|
      it "does not trip on #{column}" do
        dataset(dimensions: [ dimension(:other, column: column) ])

        expect(report).to be_ok
      end
    end
  end

  describe "metrics over a sensitive column" do
    # min and max return a stored value: metric :x, min: :email is a way to read an email.
    it "are refused without sensitive: true and explicit roles" do
      dataset(metrics: [ metric(:first_email, :min, column: :email), metric(:pw, :max, column: "customer.password_digest") ])

      expect(report.errors.grep(/looks sensitive/).size).to eq(2)
    end

    it "need explicit roles once forced" do
      dataset(metrics: [ metric(:emails_seen, :count_distinct, column: :email, sensitive: true) ])

      expect(report.errors).to include(/metric emails_seen: a sensitive metric needs explicit `roles:`/)
    end

    it "pass when forced and restricted" do
      dataset(metrics: [ metric(:emails_seen, :count_distinct, column: :email, sensitive: true, roles: :admin) ])

      expect(report).to be_ok
    end

    it "rejects a coerced flag" do
      expect { metric(:x, :sum, column: :a, sensitive: "true") }.to raise_error(DataTeller::DeclarationError, /sensitive must be true or false/)
    end
  end

  describe "segments over a sensitive column" do
    let(:segment) { DataTeller::Segment.new(name: :vip_mail, where: { email: "a@example.test" }) }

    it "need explicit roles" do
      dataset(segments: [ segment ])

      expect(report.errors).to include(/segment vip_mail: .*needs explicit `roles:`/)
    end
  end

  describe "scope: segments" do
    it "refuses a built-in ActiveRecord method, which is not a scope of the model" do
      %i[destroy_all delete_all unscoped all].each do |name|
        registry = DataTeller::Registry.new
        registry.register(DataTeller::Dataset.new(model_name: "Order", roles: %i[admin], tenant_path: %i[account],
                                                  segments: [ DataTeller::Segment.new(name: :x, scope: name, roles: :admin) ]))

        expect(described_class.new(config: config, registry: registry).call.errors)
          .to include(/segment x: `scope: :#{name}` is a built-in ActiveRecord method/)
      end
    end

    it "accepts a scope of the model" do
      dataset(segments: [ DataTeller::Segment.new(name: :vip, scope: :paid, roles: :admin) ])

      expect(report).to be_ok
    end
  end

  it "requires explicit roles on a scope segment" do
    dataset(segments: [ DataTeller::Segment.new(name: :vip, scope: :vip_customers) ])

    expect(report.errors).to include(/segment vip: a `scope:` segment needs explicit `roles:`/)
  end

  # A permission applies to every use of a column (ADR 0004 D5): a second name must not reopen it.
  describe "two dimensions on the same column" do
    it "are refused with different roles" do
      dataset(dimensions: [ dimension(:status, roles: :admin), dimension(:state, column: :status) ])

      expect(report.errors).to include(/dimensions status and state read the same column with different roles/)
    end

    it "are accepted with the same roles" do
      dataset(dimensions: [ dimension(:status, roles: :admin), dimension(:state, column: :status, roles: :admin) ])

      expect(report).to be_ok
    end
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
    config.instance_variable_set(:@tenant, nil)
    dataset(roles: nil, dimensions: [ dimension(:email) ])

    expect(report.errors.size).to be >= 3
    expect(report.message).to start_with("DataTeller configuration is invalid (").and include("no tenant:")
  end
end
