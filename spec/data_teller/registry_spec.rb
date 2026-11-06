require "rails_helper"

RSpec.describe "DataTeller declarations" do
  describe DataTeller::Metric do
    it "accepts the closed aggregation vocabulary" do
      expect(described_class.new(name: :count, aggregation: :count)).to have_attributes(column: nil, roles: nil)
      expect(described_class.new(name: :revenue, aggregation: :sum, column: :total_cents, format: :money))
        .to have_attributes(column: :total_cents, format: :money)
    end

    it "rejects an unknown aggregation (no free code in metrics)" do
      expect { described_class.new(name: :x, aggregation: -> { 1 }) }.to raise_error(DataTeller::DeclarationError, /aggregation/)
      expect { described_class.new(name: :x, aggregation: :median, column: :a) }.to raise_error(DataTeller::DeclarationError)
    end

    it "requires a column for column aggregations and forbids it for count" do
      expect { described_class.new(name: :x, aggregation: :sum) }.to raise_error(DataTeller::DeclarationError, /needs a column/)
      expect { described_class.new(name: :x, aggregation: :count, column: :id) }.to raise_error(DataTeller::DeclarationError, /does not take/)
    end

    it "builds a ratio of exactly two metrics and exposes its dependencies" do
      ratio = described_class.new(name: :avg_basket, aggregation: :ratio, of: %i[revenue count])
      expect(ratio.dependencies).to eq(%i[revenue count])
      expect { described_class.new(name: :x, aggregation: :ratio, of: [ :a ]) }.to raise_error(DataTeller::DeclarationError, /two metrics/)
      expect { described_class.new(name: :x, aggregation: :sum, column: :a, of: %i[a b]) }.to raise_error(DataTeller::DeclarationError)
    end

    it "uses strict names" do
      expect { described_class.new(name: "Revenue; drop", aggregation: :count) }.to raise_error(DataTeller::DeclarationError, /name must match/)
    end

    it "treats empty roles as an error but nil as 'inherit'" do
      expect { described_class.new(name: :x, aggregation: :count, roles: []) }.to raise_error(DataTeller::DeclarationError, /roles/)
      expect(described_class.new(name: :x, aggregation: :count, roles: %w[admin admin]).roles).to eq([ :admin ])
    end
  end

  describe DataTeller::Dimension do
    it "defaults to filterable, not sensitive, group undecided" do
      expect(described_class.new(name: :status)).to have_attributes(
        column: "status", time: false, filter: true, group: nil, sensitive: false, lookup: nil
      )
    end

    it "keeps explicit choices" do
      dimension = described_class.new(name: :customer_id, group: true, max_groups: 20, lookup: :trigram)
      expect(dimension).to have_attributes(group: true, max_groups: 20, lookup: :trigram)
    end

    it "rejects invalid flags" do
      expect { described_class.new(name: :x, lookup: :fuzzy) }.to raise_error(DataTeller::DeclarationError, /lookup/)
      expect { described_class.new(name: :x, max_groups: 0) }.to raise_error(DataTeller::DeclarationError, /max_groups/)
    end
  end

  describe DataTeller::Segment do
    it "accepts a declarative condition, frozen deeply" do
      segment = described_class.new(name: :overdue, where: { status: "pending", created_before: { days_ago: 30 } })
      expect(segment.where).to be_frozen
      expect(segment.where[:created_before]).to be_frozen
      expect(segment).not_to be_scope
    end

    it "accepts a scope by name" do
      expect(described_class.new(name: :vip, scope: :vip_customers)).to be_scope
    end

    it "requires exactly one of where: or scope:" do
      expect { described_class.new(name: :x) }.to raise_error(DataTeller::DeclarationError, /exactly one/)
      expect { described_class.new(name: :x, where: { a: 1 }, scope: :a) }.to raise_error(DataTeller::DeclarationError, /exactly one/)
    end

    it "rejects code inside a declarative condition" do
      expect { described_class.new(name: :x, where: { created_at: -> { Time.now } }) }
        .to raise_error(DataTeller::DeclarationError, /data, not code/)
    end
  end

  describe DataTeller::Dataset do
    it "derives the dataset name from the model name" do
      expect(described_class.new(model_name: "Order").name).to eq(:orders)
      expect(described_class.new(model_name: "Admin::LineItem").name).to eq(:line_items)
    end

    it "indexes declarations by name and refuses duplicates" do
      count = DataTeller::Metric.new(name: :count, aggregation: :count)
      dataset = described_class.new(model_name: "Order", metrics: [ count ])
      expect(dataset.metrics[:count]).to eq(count)
      expect { described_class.new(model_name: "Order", metrics: [ count, count ]) }
        .to raise_error(DataTeller::DeclarationError, /declared twice/)
    end

    it "cleans synonyms" do
      expect(described_class.new(model_name: "Order", synonyms: [ " commande ", "", "commande", :achat ]).synonyms)
        .to eq(%w[commande achat])
    end

    it "is deeply immutable" do
      dataset = described_class.new(model_name: "Order", roles: [ :admin ])
      expect(dataset.metrics).to be_frozen
      expect(dataset.roles).to be_frozen
      expect { dataset.synonyms << "x" }.to raise_error(FrozenError)
    end
  end

  describe DataTeller::Registry do
    subject(:registry) { described_class.new }

    let(:orders) { DataTeller::Dataset.new(model_name: "Order", roles: [ :admin ]) }

    it "registers and finds datasets by name" do
      registry.register(orders)
      expect(registry.dataset(:orders)).to eq(orders)
      expect(registry.dataset("orders")).to eq(orders)
      expect(registry.dataset(:unknown)).to be_nil
    end

    it "refuses a dataset declared twice" do
      registry.register(orders)
      expect { registry.register(orders) }.to raise_error(DataTeller::DeclarationError, /twice/)
    end

    it "refuses any declaration once frozen" do
      registry.freeze!
      expect { registry.register(orders) }.to raise_error(DataTeller::DeclarationError, /frozen/)
    end

    it "has no version before being frozen" do
      expect { registry.version }.to raise_error(DataTeller::DeclarationError, /frozen/)
    end

    it "has a stable version that changes with the declarations" do
      registry.register(orders)
      first = registry.freeze!.version

      same = described_class.new
      same.register(DataTeller::Dataset.new(model_name: "Order", roles: [ :admin ]))
      expect(same.freeze!.version).to eq(first)

      different = described_class.new
      different.register(DataTeller::Dataset.new(model_name: "Order", roles: [ :admin, :support ]))
      expect(different.freeze!.version).not_to eq(first)
    end

    def version_of(**parts)
      described_class.new.tap { |r| r.register(DataTeller::Dataset.new(model_name: "Order", roles: [ :admin ], **parts)) }.freeze!.version
    end

    it "does not depend on the order of roles or of a condition's keys and lists" do
      metric = ->(roles) { [ DataTeller::Metric.new(name: :x, aggregation: :count, roles: roles) ] }
      segment = ->(where) { [ DataTeller::Segment.new(name: :x, where: where) ] }

      expect(version_of(metrics: metric.call(%i[a b]))).to eq(version_of(metrics: metric.call(%i[b a])))
      expect(version_of(segments: segment.call({ a: 1, b: 2 }))).to eq(version_of(segments: segment.call({ b: 2, a: 1 })))
      expect(version_of(segments: segment.call({ a: %i[x y] }))).to eq(version_of(segments: segment.call({ a: %i[y x] })))
    end

    it "keeps the order of a ratio, where a / b is not b / a" do
      ratio = ->(of) { [ DataTeller::Metric.new(name: :x, aggregation: :ratio, of: of) ] }

      expect(version_of(metrics: ratio.call(%i[a b]))).not_to eq(version_of(metrics: ratio.call(%i[b a])))
    end

    it "does not depend on declaration order for the version" do
      one = described_class.new
      two = described_class.new
      customers = DataTeller::Dataset.new(model_name: "Customer", roles: [ :admin ])
      [ orders, customers ].each { |d| one.register(d) }
      [ customers, orders ].each { |d| two.register(d) }
      expect(one.freeze!.version).to eq(two.freeze!.version)
    end
  end

  describe "DataTeller.registry" do
    after do
      DataTeller.reset!
      DataTeller.boot!(Rails.root)
    end

    it "is shared until reset" do
      expect(DataTeller.registry).to equal(DataTeller.registry)
      first = DataTeller.registry
      DataTeller.reset!
      expect(DataTeller.registry).not_to equal(first)
    end

    it "is empty and frozen until a boot has validated declarations" do
      DataTeller.reset!

      expect(DataTeller.registry.datasets).to be_empty
      expect(DataTeller.registry).to be_frozen
    end
  end
end
