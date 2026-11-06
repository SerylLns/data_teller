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
    it "requires a block" do
      expect { config.tenant }.to raise_error(DataTeller::ConfigurationError, /needs a block/)
    end

    it "resolves the tenant of a user" do
      config.tenant { |user| user[:account] }
      expect(config.tenant_for({ account: "acme" })).to eq("acme")
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
