require "rails_helper"

RSpec.describe "DataTeller.refine" do
  before { DataTeller.reset! }
  after { DataTeller.reset! }

  def refine_orders(&block)
    DataTeller.refine(Order, &block)
    DataTeller.registry.dataset(:orders)
  end

  it "builds a dataset from the block and registers it" do
    dataset = refine_orders do
      roles :admin, :support
      synonyms "commande", "order"
      metric :revenue, sum: :total_cents, format: :money
      metric :avg_basket, ratio: %i[revenue count]
      dimension :status
      dimension :ship_on, time: true
      segment :paid, where: { status: :paid }
    end

    expect(dataset).to have_attributes(name: :orders, model_name: "Order", roles: %i[admin support], synonyms: %w[commande order])
    expect(dataset.metrics.keys).to contain_exactly(:count, :revenue, :avg_basket)
    expect(dataset.metrics[:revenue]).to have_attributes(aggregation: :sum, column: :total_cents, format: :money)
    expect(dataset.metrics[:avg_basket].dependencies).to eq(%i[revenue count])
    expect(dataset.dimensions[:ship_on].time).to be(true)
    expect(dataset.segments[:paid].where).to eq({ status: :paid })
  end

  it "accepts the model as a class or as a name" do
    DataTeller.refine("Order") { roles :admin }
    expect(DataTeller.registry.dataset(:orders).model_name).to eq("Order")
  end

  it "adds the implicit count metric unless it is declared" do
    expect(refine_orders { roles :admin }.metrics[:count]).to have_attributes(aggregation: :count, roles: nil)
  end

  it "lets the developer restrict the implicit count" do
    dataset = refine_orders do
      roles :admin, :support
      metric :count, roles: :admin
    end

    expect(dataset.metrics[:count].roles).to eq([ :admin ])
  end

  describe "declaration errors" do
    it "needs a block" do
      expect { DataTeller.refine(Order) }.to raise_error(DataTeller::DeclarationError, /block/)
    end

    it "rejects a metric without an aggregation, or with two" do
      expect { refine_orders { metric :revenue } }.to raise_error(DataTeller::DeclarationError, /give an aggregation/)
      expect { refine_orders { metric :x, sum: :a, avg: :b } }.to raise_error(DataTeller::DeclarationError, /one aggregation/)
    end

    it "rejects an aggregation outside the closed set" do
      expect { refine_orders { metric :x, median: :a } }.to raise_error(DataTeller::DeclarationError, /aggregation/)
    end

    it "rejects a lambda where a column is expected (no free code in metrics)" do
      expect { refine_orders { metric :x, sum: -> { 1 } } }.to raise_error(DataTeller::DeclarationError, /column name/)
    end

    it "reports unknown options as declaration errors, with the model name" do
      expect { refine_orders { dimension :status, colour: :red } }
        .to raise_error(DataTeller::DeclarationError, /Order.*colour/)
      expect { refine_orders { segment :paid, where: { status: :paid }, order: :asc } }
        .to raise_error(DataTeller::DeclarationError, /Order/)
    end

    it "rejects a lambda in a segment" do
      expect { refine_orders { segment :today, where: -> { Date.today } } }.to raise_error(DataTeller::DeclarationError, /data, not code/)
    end

    it "rejects a duplicate name inside a dataset and a dataset declared twice" do
      expect { refine_orders { dimension :status; dimension :status } }.to raise_error(DataTeller::DeclarationError, /twice/)
      DataTeller.refine(Order) { roles :admin }
      expect { DataTeller.refine(Order) { roles :admin } }.to raise_error(DataTeller::DeclarationError, /twice/)
    end
  end
end
