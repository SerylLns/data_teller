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

  after do
    DataTeller.reset!
    DataTeller.boot!(Rails.root)
  end

  def write(path, content)
    @root.join(path).tap { |file| file.dirname.mkpath }.write(content)
  end

  let(:valid_global) { "DataTeller.configure { |c| c.tenant { model 'Account'; resolve { |u| u.account } }; c.expose 'Order' }" }
  let(:disabling_global) { "DataTeller.configure { |c| c.on_invalid_config = :disable; c.tenant { model 'Account'; resolve { |u| u.account } }; c.expose 'Order' }" }
  let(:valid_dataset) { "DataTeller.refine('Order') { roles :admin; tenant_path :account }" }

  def expect_closed
    expect(DataTeller).not_to be_enabled
    expect(DataTeller.registry.datasets).to be_empty
    expect(DataTeller.registry).to be_frozen
    expect(DataTeller.config.tenant_resolver).to be_nil
  end

  describe "valid configuration" do
    before do
      write("config/data_teller.rb", valid_global)
      write("config/data_teller/orders.rb", valid_dataset)
      DataTeller.boot!(@root)
    end

    it "enables the engine and publishes frozen declarations" do
      expect(DataTeller).to be_enabled
      expect(DataTeller.registry).to be_frozen
      expect(DataTeller.registry.version).to match(/\A\h{16}\z/)
      expect(DataTeller.registry.dataset(:orders)).to be_present
      expect(DataTeller.config.tenant_resolver).to be_present
    end
  end

  it "boots the dummy app" do
    DataTeller.boot!(Rails.root)

    expect(DataTeller).to be_enabled
  end

  describe "no configuration at all" do
    it "keeps the engine off with a warning, so that the install generator and db:migrate can run" do
      allow(Rails.logger).to receive(:warn)

      expect { DataTeller.boot!(@root) }.not_to raise_error

      expect_closed
      expect(Rails.logger).to have_received(:warn).with(/not configured.*rails generate data_teller:install/)
    end

    it "still applies the strict rule when only dataset files exist" do
      write("config/data_teller/orders.rb", valid_dataset)

      expect { DataTeller.boot!(@root) }.to raise_error(DataTeller::ConfigurationError, /no tenant:/)
      expect_closed
    end
  end

  describe "invalid configuration" do
    it "refuses to boot by default and lists every problem" do
      write("config/data_teller.rb", "DataTeller.configure { |c| c.expose 'Order' }")

      expect { DataTeller.boot!(@root) }
        .to raise_error(DataTeller::ConfigurationError, /no tenant:.*\n.*Order is exposed but has no/m)
      expect_closed
    end

    it "disables the engine instead, with a log, when asked to" do
      write("config/data_teller.rb", "DataTeller.configure { |c| c.on_invalid_config = :disable; c.expose 'Order' }")
      allow(Rails.logger).to receive(:error)

      expect { DataTeller.boot!(@root) }.not_to raise_error

      expect_closed
      expect(Rails.logger).to have_received(:error).with(/DISABLED.*no tenant:/m)
    end
  end

  # Anything a Ruby file can raise, not only our own errors.
  {
    "an unknown constant" => "DataTeller.refine(Ordr) { roles :admin }",
    "a typo in the DSL" => "DataTeller.refine('Order') { roles :admin; metrc :x }",
    "a wrong argument" => "DataTeller.refine('Order') { roles :admin; dimension :x, 'bad' }",
    "a syntax error" => "DataTeller.refine('Order') do",
    "a missing require" => "require 'data_teller_no_such_file'",
    "an arbitrary exception" => "raise 'boom'"
  }.each do |label, source|
    describe "a declaration file with #{label}" do
      before { write("config/data_teller/orders.rb", source) }

      it "is reported with the file name and leaves the engine closed under :raise" do
        write("config/data_teller.rb", valid_global)

        expect { DataTeller.boot!(@root) }.to raise_error(DataTeller::ConfigurationError, /orders\.rb/)
        expect_closed
      end

      it "does not take the host app down under :disable" do
        write("config/data_teller.rb", disabling_global)

        expect { DataTeller.boot!(@root) }.not_to raise_error
        expect_closed
      end
    end
  end

  it "fails loud when the global file breaks before it could choose :disable" do
    write("config/data_teller.rb", "raise 'boom'\nDataTeller.configure { |c| c.on_invalid_config = :disable }")

    expect { DataTeller.boot!(@root) }.to raise_error(DataTeller::ConfigurationError, /data_teller\.rb:1.*boom/)
    expect_closed
  end

  describe "a reload after a valid boot" do
    before do
      write("config/data_teller.rb", valid_global)
      write("config/data_teller/orders.rb", valid_dataset)
      DataTeller.boot!(@root)
    end

    it "closes the engine when the new declarations are invalid" do
      write("config/data_teller/z_broken.rb", "DataTeller.refine(Ordr) { }")

      expect { DataTeller.boot!(@root) }.to raise_error(DataTeller::ConfigurationError)
      expect_closed
    end

    it "notices a tenant resolver that was removed" do
      write("config/data_teller.rb", "DataTeller.configure { |c| c.expose 'Order' }")

      expect { DataTeller.boot!(@root) }.to raise_error(DataTeller::ConfigurationError, /no tenant:/)
    end

    it "forgets an exposed model that was removed" do
      write("config/data_teller.rb", "DataTeller.configure { |c| c.tenant { model 'Account'; resolve { |u| u } }; c.expose 'Order', 'Customer' }")
      write("config/data_teller/customers.rb", "DataTeller.refine('Customer') { roles :admin; tenant_path :account }")
      DataTeller.boot!(@root)

      write("config/data_teller.rb", valid_global)
      @root.join("config/data_teller/customers.rb").delete
      DataTeller.boot!(@root)

      expect(DataTeller).to be_enabled
      expect(DataTeller.config.exposed_models).to eq([ "Order" ])
    end
  end

  describe "DataTeller.check" do
    before do
      write("config/data_teller.rb", valid_global)
      write("config/data_teller/orders.rb", valid_dataset)
      DataTeller.boot!(@root)
    end

    it "leaves the running engine untouched, whatever it finds" do
      live_registry = DataTeller.registry
      live_config = DataTeller.config
      write("config/data_teller/z_broken.rb", "DataTeller.refine(Ordr) { }")

      report = DataTeller.check(@root)

      expect(report).not_to be_ok
      expect(DataTeller).to be_enabled
      expect(DataTeller.registry).to equal(live_registry)
      expect(DataTeller.registry).to be_frozen
      expect(DataTeller.config).to equal(live_config)
    end
  end

  it "reports a missing configuration as an error in DataTeller.check, for CI" do
    expect(DataTeller.check(@root).errors).to include(/no configuration found.*rails generate data_teller:install/)
  end

  describe "a deferred boot" do
    it "keeps the engine closed without raising, and leaves the reporting to the caller" do
      write("config/data_teller.rb", "DataTeller.configure { |c| c.expose 'Order' }")

      DataTeller.defer_boot!

      expect { DataTeller.boot!(@root) }.not_to raise_error
      expect_closed
    end
  end

  describe "declarations outside the declaration files" do
    it "are refused with a pointer to the right file, instead of being silently lost" do
      expect { DataTeller.refine("Order") { roles :admin } }
        .to raise_error(DataTeller::DeclarationError, %r{config/data_teller/})
      expect { DataTeller.configure { |c| c.expose "Order" } }
        .to raise_error(DataTeller::ConfigurationError, %r{config/data_teller\.rb})
    end
  end
end
