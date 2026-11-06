require "rails_helper"
require "tmpdir"

RSpec.describe DataTeller::Loader do
  after { described_class.load!(Rails.root) }

  it "loads the dummy app declarations" do
    described_class.load!(Rails.root)

    expect(DataTeller.registry.dataset(:orders).metrics.keys).to include(:count, :revenue, :avg_basket, :customers)
    expect(DataTeller.config.exposed_models).to contain_exactly("Order", "Customer")
  end

  it "rebuilds the registry on reload instead of declaring twice" do
    2.times { described_class.load!(Rails.root) }

    expect(DataTeller.registry.datasets.size).to eq(2)
  end

  it "names the file when a declaration is invalid" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      root.join("config/data_teller").mkpath
      root.join("config/data_teller/orders.rb").write("DataTeller.refine('Order') { metric :x, median: :a }")

      expect { described_class.load!(root) }
        .to raise_error(DataTeller::DeclarationError, %r{\Aconfig/data_teller/orders\.rb: .*aggregation})
    end
  end

  it "does nothing when the app has no declaration files" do
    Dir.mktmpdir do |dir|
      described_class.load!(Pathname(dir))

      expect(DataTeller.registry.datasets).to be_empty
    end
  end
end
