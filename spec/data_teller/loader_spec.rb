require "rails_helper"
require "tmpdir"

RSpec.describe DataTeller::Loader do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  def write(path, content)
    @root.join(path).tap { |file| file.dirname.mkpath }.write(content)
  end

  it "loads the dummy app declarations into isolated objects" do
    loaded = described_class.call(Rails.root)

    expect(loaded.errors).to eq([])
    expect(loaded.registry.dataset(:orders).metrics.keys).to include(:count, :revenue, :avg_basket, :customers)
    expect(loaded.config.exposed_models).to contain_exactly("Order", "Customer")
    expect(loaded.registry).not_to equal(DataTeller.registry)
    expect(loaded.config).not_to equal(DataTeller.config)
  end

  it "builds fresh objects on every call" do
    2.times { expect(described_class.call(Rails.root).registry.datasets.size).to eq(2) }
  end

  it "names the file and the line when a declaration is invalid" do
    write("config/data_teller/orders.rb", "\nDataTeller.refine('Order') { metric :x, median: :a }")

    expect(described_class.call(@root).errors)
      .to contain_exactly(%r{\Aconfig/data_teller/orders\.rb:2: .*aggregation})
  end

  it "reads every file instead of stopping at the first broken one" do
    write("config/data_teller/a.rb", "DataTeller.refine('A') { metric :x, median: :a }")
    write("config/data_teller/b.rb", "DataTeller.refine(Bee) { }")
    write("config/data_teller/c.rb", "DataTeller.refine('Cat') { roles :admin }")

    loaded = described_class.call(@root)

    expect(loaded.errors).to contain_exactly(/a\.rb.*aggregation/, /b\.rb.*Bee/)
    expect(loaded.registry.dataset(:cats)).to be_present
  end

  it "reports every bad line of one dataset" do
    write("config/data_teller/orders.rb", <<~RUBY)
      DataTeller.refine('Order') do
        metric :x, median: :a
        dimension :status, colour: :red
        segment :paid, where: "1=1"
      end
    RUBY

    expect(described_class.call(@root).errors)
      .to contain_exactly(/aggregation/, /colour/, /where: must be a non-empty Hash/)
  end

  describe "with DataTeller.check" do
    it "reports the problems of every file along with the validator's" do
      write("config/data_teller.rb", "DataTeller.configure { |c| c.expose 'Order' }")
      write("config/data_teller/a.rb", "DataTeller.refine('Order') { metric :x, median: :a }")
      write("config/data_teller/b.rb", "DataTeller.refine(Bee) { }")

      expect(DataTeller.check(@root).errors).to contain_exactly(/no tenant resolver/, /a\.rb.*aggregation/, /b\.rb.*Bee/)
    end

    it "does not claim a model has no refine block when its file failed to load" do
      write("config/data_teller.rb", "DataTeller.configure { |c| c.tenant { |u| u }; c.expose 'Order' }")
      write("config/data_teller/orders.rb", "DataTeller.refine(Ordr) { }")

      expect(DataTeller.check(@root).errors).to contain_exactly(/orders\.rb.*Ordr/)
    end

    it "does not claim the tenant is missing when the global file failed before setting it" do
      write("config/data_teller.rb", "raise 'boom'")

      expect(DataTeller.check(@root).errors).to contain_exactly(/data_teller\.rb.*boom/)
    end
  end

  it "knows when nothing is configured" do
    expect(described_class.configured?(@root)).to be(false)

    write("config/data_teller/orders.rb", "")
    expect(described_class.configured?(@root)).to be(true)
  end

  it "restores the previous context even if the block raises" do
    expect { described_class.capture { raise "boom" } }.to raise_error("boom")
    expect(described_class.current).to be_nil
  end
end
