require "rails_helper"
require "tmpdir"

RSpec.describe "DataTeller.boot!" do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  before { DataTeller.reset! }
  after { DataTeller.boot!(Rails.root) }

  def write(path, content)
    @root.join(path).tap { |file| file.dirname.mkpath }.write(content)
  end

  let(:valid_global) { "DataTeller.configure { |c| c.tenant { |u| u.account }; c.expose 'Order' }" }
  let(:valid_dataset) { "DataTeller.refine('Order') { roles :admin }" }

  it "enables the engine and freezes the registry when the configuration is valid" do
    write("config/data_teller.rb", valid_global)
    write("config/data_teller/orders.rb", valid_dataset)

    DataTeller.boot!(@root)

    expect(DataTeller).to be_enabled
    expect(DataTeller.registry).to be_frozen
    expect(DataTeller.registry.version).to match(/\A\h{16}\z/)
  end

  it "boots the dummy app" do
    DataTeller.boot!(Rails.root)

    expect(DataTeller).to be_enabled
  end

  describe "invalid configuration" do
    before { write("config/data_teller.rb", "DataTeller.configure { |c| c.expose 'Order' }") }

    it "refuses to boot by default and lists every problem" do
      expect { DataTeller.boot!(@root) }
        .to raise_error(DataTeller::ConfigurationError, /no tenant resolver.*\n.*Order is exposed but has no/m)
      expect(DataTeller).not_to be_enabled
    end

    it "disables the engine instead, with a log, when asked to" do
      write("config/data_teller.rb", "DataTeller.configure { |c| c.on_invalid_config = :disable; c.expose 'Order' }")
      allow(Rails.logger).to receive(:error)

      expect { DataTeller.boot!(@root) }.not_to raise_error

      expect(DataTeller).not_to be_enabled
      expect(DataTeller.registry).not_to be_frozen
      expect(Rails.logger).to have_received(:error).with(/DISABLED.*no tenant resolver/m)
    end
  end

  it "treats a broken declaration file like an invalid configuration" do
    write("config/data_teller.rb", valid_global)
    write("config/data_teller/orders.rb", "DataTeller.refine('Order') { metric :x, median: :a }")

    expect { DataTeller.boot!(@root) }.to raise_error(DataTeller::ConfigurationError, /orders\.rb.*aggregation/m)
    expect(DataTeller).not_to be_enabled
  end

  it "stays disabled when a later reload is invalid" do
    write("config/data_teller.rb", valid_global)
    write("config/data_teller/orders.rb", valid_dataset)
    DataTeller.boot!(@root)

    write("config/data_teller/orders.rb", "DataTeller.refine('Order') { }")
    expect { DataTeller.boot!(@root) }.to raise_error(DataTeller::ConfigurationError)

    expect(DataTeller).not_to be_enabled
  end
end
