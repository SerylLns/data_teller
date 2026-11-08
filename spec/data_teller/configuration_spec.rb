require "rails_helper"

RSpec.describe DataTeller::Configuration do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "fails hard on invalid config" do
      expect(config.on_invalid_config).to eq(:raise)
    end

    it "mounts the palette as a modal with the system theme and mod+k" do
      expect(config.ui).to have_attributes(mode: :modal, theme: :system, keyboard_shortcut: "mod+k")
    end

    it "has no tenant resolver, no roles resolver and no exposed model" do
      expect(config).to have_attributes(tenant_resolver: nil, roles_resolver: nil, exposed_models: [])
    end
  end

  describe "on_invalid_config" do
    it "accepts :disable" do
      config.on_invalid_config = :disable
      expect(config.on_invalid_config).to eq(:disable)
    end

    it "rejects unknown values" do
      expect { config.on_invalid_config = :ignore }.to raise_error(DataTeller::ConfigurationError, /on_invalid_config/)
    end
  end

  describe "database_role" do
    it "is off by default" do
      expect(config.database_role).to be_nil
    end

    it "takes a plain role name, and nil to turn it off again" do
      config.database_role = "data_teller_reader"
      expect(config.database_role).to eq("data_teller_reader")

      config.database_role = nil
      expect(config.database_role).to be_nil
    end

    it "refuses anything that is not a plain lowercase name" do
      [ "", "Reader", "1reader", "reader; DROP TABLE orders", %("reader"), "a" * 64, :data_teller_reader ].each do |value|
        expect { config.database_role = value }.to raise_error(DataTeller::ConfigurationError, /database_role/), value.inspect
      end
    end
  end

  describe "row_security" do
    it "is off by default, and takes true or false only" do
      expect(config.row_security).to be(false)

      config.row_security = true
      expect(config.row_security).to be(true)
      [ nil, "true", 1, :on ].each do |value|
        expect { config.row_security = value }.to raise_error(DataTeller::ConfigurationError, /row_security/), value.inspect
      end
    end
  end

  describe "llm and router_llm" do
    let(:adapter_class) do
      Struct.new(:name) do
        def complete(system:, user:, schema:) = nil
        def provider_schema(schema) = schema
      end
    end

    it "has no adapter by default" do
      expect(config.llm).to be_nil
      expect(config.router_llm).to be_nil
    end

    it "routes with the same adapter unless told otherwise" do
      main = adapter_class.new("main")
      config.llm = main
      expect(config.router_llm).to equal(main)

      small = adapter_class.new("small")
      config.router_llm = small
      expect(config.router_llm).to equal(small)
      expect(config.llm).to equal(main)
    end

    it "takes any object with the two methods, and refuses the rest" do
      expect { config.llm = Object.new }.to raise_error(DataTeller::ConfigurationError, /complete\(system:, user:, schema:\) and provider_schema\(schema\), got Object/)
      expect { config.router_llm = ->(request) { request } }.to raise_error(DataTeller::ConfigurationError, /router_llm/)
      expect { config.llm = nil }.not_to raise_error
    end
  end

  describe "limits" do
    it "has defaults" do
      expect(config).to have_attributes(statement_timeout: 5, default_max_groups: 50, max_rows: 1_000, max_time_points: 366, max_joins: 5)
    end

    it "can be set" do
      config.statement_timeout = 0.5
      config.max_rows = 10

      expect(config).to have_attributes(statement_timeout: 0.5, max_rows: 10)
    end

    # A timeout of 0 means no timeout at all in Postgres: a typo must not switch the protection off.
    it "refuses zero, negatives and anything that is not a number" do
      expect { config.statement_timeout = 0 }.to raise_error(DataTeller::ConfigurationError, /statement_timeout/)
      expect { config.statement_timeout = -1 }.to raise_error(DataTeller::ConfigurationError, /statement_timeout/)
      expect { config.statement_timeout = "5; DROP" }.to raise_error(DataTeller::ConfigurationError, /statement_timeout/)
      expect { config.statement_timeout = 0.0001 }.to raise_error(DataTeller::ConfigurationError, /statement_timeout/)
      expect { config.statement_timeout = Float::INFINITY }.to raise_error(DataTeller::ConfigurationError, /statement_timeout/)
      expect { config.statement_timeout = Float::NAN }.to raise_error(DataTeller::ConfigurationError, /statement_timeout/)
      expect { config.statement_timeout = Complex(1, 1) }.to raise_error(DataTeller::ConfigurationError, /statement_timeout/)
      expect { config.max_rows = 0 }.to raise_error(DataTeller::ConfigurationError, /max_rows/)
      expect { config.max_joins = 1.5 }.to raise_error(DataTeller::ConfigurationError, /max_joins/)
      expect { config.default_max_groups = nil }.to raise_error(DataTeller::ConfigurationError, /default_max_groups/)
      expect { config.max_time_points = "many" }.to raise_error(DataTeller::ConfigurationError, /max_time_points/)
    end

    it "takes 0 for route_above_datasets, the router on every question, and refuses the rest" do
      expect(config.route_above_datasets).to eq(12)

      config.route_above_datasets = 0
      expect(config.route_above_datasets).to eq(0)
      expect { config.route_above_datasets = -1 }.to raise_error(DataTeller::ConfigurationError, /route_above_datasets/)
      expect { config.route_above_datasets = "many" }.to raise_error(DataTeller::ConfigurationError, /route_above_datasets/)
    end
  end

  describe "ui" do
    it "rejects unknown modes and themes" do
      expect { config.ui.mode = :page }.to raise_error(DataTeller::ConfigurationError, /ui.mode/)
      expect { config.ui.theme = :neon }.to raise_error(DataTeller::ConfigurationError, /ui.theme/)
    end

    it "lets the shortcut be disabled with nil but rejects blank strings" do
      config.ui.keyboard_shortcut = nil
      expect(config.ui.keyboard_shortcut).to be_nil
      expect { config.ui.keyboard_shortcut = " " }.to raise_error(DataTeller::ConfigurationError)
    end
  end

  describe "#tenant" do
    let(:acme) { Account.new(name: "Acme") }

    def declare_tenant(&resolver)
      config.tenant do
        model Account
        resolve(&resolver)
      end
    end

    it "requires a block" do
      expect { config.tenant }.to raise_error(DataTeller::ConfigurationError, /needs a block/)
    end

    it "keeps the model by name, like expose, so a reload never leaves a stale class" do
      declare_tenant { |user| user }
      expect(config.tenant_model_name).to eq("Account")

      config.tenant { model "Account" }
      expect(config.tenant_model_name).to eq("Account")
    end

    it "requires a block on resolve" do
      expect { config.tenant { resolve } }.to raise_error(DataTeller::ConfigurationError, /resolve needs a block/)
    end

    it "resolves the tenant of a user" do
      declare_tenant { |user| user[:account] }
      expect(config.tenant_for({ account: acme })).to eq(acme)
    end

    it "accepts a subclass of the tenant model" do
      subclass = Class.new(Account)
      declare_tenant { |_user| subclass.new }
      expect(config.tenant_for(:user)).to be_a(Account)
    end

    describe "fails closed" do
      it "with no tenant declared" do
        expect(config.tenant_for(:user)).to be_nil
      end

      it "when the resolver returns nil" do
        declare_tenant { |_user| nil }
        expect(config.tenant_for(:user)).to be_nil
      end

      # A resolver returning another record would scope every query to the wrong thing.
      it "when the resolver returns anything but the tenant model" do
        declare_tenant { |_user| Customer.new }
        allow(Rails.logger).to receive(:error)

        expect(config.tenant_for(:user)).to be_nil
        expect(Rails.logger).to have_received(:error).with(/tenant resolver returned Customer, expected Account/)
      end

      it "when the resolver raises, without logging the message" do
        declare_tenant { |_user| raise "secret detail" }
        allow(Rails.logger).to receive(:error)

        expect(config.tenant_for(:user)).to be_nil
        expect(Rails.logger).to have_received(:error).with(/tenant resolver failed.*RuntimeError/)
        expect(Rails.logger).not_to have_received(:error).with(/secret detail/)
      end
    end
  end

  describe "#time_zone_for" do
    let(:acme) { Account.new(time_zone: "Europe/Paris") }

    def declare_zone(&block)
      config.tenant { time_zone(&block) }
    end

    it "uses the tenant's zone" do
      declare_zone(&:time_zone)
      expect(config.time_zone_for(acme).tzinfo.name).to eq("Europe/Paris")
    end

    it "uses the app's zone when none is declared" do
      expect(config.time_zone_for(acme)).to eq(Time.zone)
    end

    it "gives nothing for an unknown zone or a failing resolver: a wrong today is a wrong answer" do
      declare_zone { "Mars/Olympus" }
      expect(config.time_zone_for(acme)).to be_nil

      declare_zone { raise "boom" }
      expect(config.time_zone_for(acme)).to be_nil
    end
  end

  describe "#roles_for" do
    it "returns no role when no resolver is configured" do
      expect(config.roles_for(:anyone)).to eq([])
    end

    it "normalizes to unique symbols" do
      config.roles { |_user| [ "admin", :admin, "support" ] }
      expect(config.roles_for(:user)).to eq(%i[admin support])
    end

    it "fails closed when the resolver returns nil" do
      config.roles { |_user| nil }
      expect(config.roles_for(:user)).to eq([])
    end

    it "fails closed when the resolver raises" do
      config.roles { |_user| raise "boom" }
      expect(config.roles_for(:user)).to eq([])
    end

    it "calls the resolver on every request instead of caching" do
      calls = 0
      config.roles do |_user|
        calls += 1
        [ :admin ]
      end
      2.times { config.roles_for(:user) }
      expect(calls).to eq(2)
    end
  end

  describe "#expose" do
    it "keeps model names, without duplicates" do
      config.expose(Order, "Customer", Order)
      expect(config.exposed_models).to eq(%w[Order Customer])
    end

    it "does not let callers mutate the list" do
      config.expose(Order)
      expect { config.exposed_models << "Hack" }.to raise_error(FrozenError)
    end
  end
end

RSpec.describe "The published configuration" do
  it "cannot be changed once the engine is running, so a resolver cannot be swapped at runtime" do
    expect(DataTeller).to be_enabled

    expect { DataTeller.config.tenant { model Account } }.to raise_error(FrozenError)
    expect { DataTeller.config.expose "Hack" }.to raise_error(FrozenError)
    expect { DataTeller.config.on_invalid_config = :disable }.to raise_error(FrozenError)
    expect { DataTeller.config.ui.theme = :dark }.to raise_error(FrozenError)
  end

  it "cannot be filled in behind the validator while the engine is closed" do
    DataTeller.reset!

    expect { DataTeller.config.tenant { model Account } }.to raise_error(FrozenError)
  ensure
    DataTeller.boot!(Rails.root)
  end

  it "stays writable while a file is being loaded" do
    loaded = DataTeller::Loader.capture { DataTeller.configure { |c| c.tenant { resolve { |user| user } } } }

    expect(loaded.config.tenant_resolver).to be_present
  end
end

RSpec.describe "DataTeller.configure" do
  it "writes into the configuration being loaded" do
    config = DataTeller::Loader.capture do
      DataTeller.configure do |c|
        c.on_invalid_config = :disable
        c.ui.theme = :dark
      end
    end.config

    expect(config.on_invalid_config).to eq(:disable)
    expect(config.ui.theme).to eq(:dark)
  end

  it "does not touch the live configuration" do
    live = DataTeller.config

    DataTeller::Loader.capture { DataTeller.configure { |c| c.ui.mode = :inline } }

    expect(DataTeller.config).to equal(live)
    expect(DataTeller.config.ui.mode).to eq(:modal)
  end
end
