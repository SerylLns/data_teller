require "rails_helper"

RSpec.describe DataTeller::Ask do
  include ActiveSupport::Testing::TimeHelpers

  let(:acme) { Account.find_or_create_by!(name: "AskSpec Acme") { |account| account.time_zone = "Asia/Tokyo" } }
  let(:globex) { Account.find_or_create_by!(name: "AskSpec Globex") { |account| account.time_zone = "UTC" } }
  let(:user_class) { Struct.new(:account, :roles) }
  let(:admin) { user_class.new(acme, [ :admin ]) }
  let(:count_orders) { { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "count" } }
  let(:adapter_class) do
    Struct.new(:outputs, :calls) do
      def provider_schema(schema) = schema

      def complete(system:, user:, schema:)
        calls << { system: system, user: user, schema: schema }
        output = outputs.shift
        raise output if output.is_a?(Exception)

        DataTeller::LLM::Response.new(output: output, input_tokens: 100, cached_input_tokens: 40, output_tokens: 10, latency_ms: 200, model: "fake")
      end
    end
  end

  def with_llm(adapter)
    config = DataTeller.config.dup.tap { |copy| copy.llm = adapter }
    allow(DataTeller).to receive(:config).and_return(config)
    adapter
  end

  def reason(outcome) = outcome.refusal&.reason

  it "turns a question into rows, for the user's tenant only" do
    customer = Customer.create!(account: acme, name: "A", email: "a@example.test", city: "Paris")
    Order.create!(account: acme, customer: customer, status: :paid, total_cents: 100, ordered_at: Time.current)
    other = Customer.create!(account: globex, name: "B", email: "b@example.test", city: "Lyon")
    Order.create!(account: globex, customer: other, status: :paid, total_cents: 100, ordered_at: Time.current)
    with_llm(adapter_class.new([ count_orders ], []))

    outcome = DataTeller.ask("how many orders?", user: admin)

    expect(outcome.status).to eq(:answered)
    expect(outcome.result.value).to eq(1)
  end

  it "gives the model the day in the tenant's time zone and the question apart from the prompt" do
    adapter = with_llm(adapter_class.new([ count_orders ], []))

    DataTeller.ask("  how many orders?  ", user: admin, now: Time.utc(2026, 11, 4, 20, 0))

    expect(adapter.calls.first[:system]).to include("Today is 2026-11-05 (Asia/Tokyo).")
    expect(adapter.calls.first[:user]).to eq("how many orders?")
  end

  it "shows the model the role's catalog only" do
    adapter = with_llm(adapter_class.new([ count_orders ], []))

    DataTeller.ask("?", user: user_class.new(acme, [ :member ]))

    expect(adapter.calls.first[:system]).to include("Catalog for member.")
    expect(adapter.calls.first[:system]).not_to include("revenue", "customers (")
  end

  it "judges the model's answer like any other query: it cannot reach beyond the role" do
    with_llm(adapter_class.new([ { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "revenue" } ], []))

    outcome = DataTeller.ask("?", user: user_class.new(acme, [ :member ]))

    expect(outcome.status).to eq(:refused)
    expect(reason(outcome)).to eq(:unknown_metric)
  end

  it "passes a clarification and an out of scope through" do
    clarify = { "version" => 1, "intent" => "clarify", "clarify" => { "reason" => "ambiguous_metric", "options" => %w[revenue net_revenue] } }
    outside = { "version" => 1, "intent" => "out_of_scope", "out_of_scope" => { "reason" => "not_a_data_question" } }
    with_llm(adapter_class.new([ clarify, outside ], []))

    expect(DataTeller.ask("?", user: admin)).to have_attributes(status: :clarify, query: clarify)
    expect(DataTeller.ask("?", user: admin)).to have_attributes(status: :out_of_scope, query: outside)
  end

  describe "what stops a question before a provider is paid" do
    let!(:adapter) { with_llm(adapter_class.new([], [])) }

    after { expect(adapter.calls).to be_empty }

    [ nil, "", "   ", 42, [ "orders" ], "x" * 501 ].each do |question|
      it "refuses #{question.inspect.truncate(20)} as a question" do
        expect(reason(DataTeller.ask(question, user: admin))).to eq(:invalid_question)
      end
    end

    it "refuses a user with no tenant" do
      expect(reason(DataTeller.ask("?", user: user_class.new(nil, [ :admin ])))).to eq(:no_tenant)
    end

    it "gives a role that sees nothing the answer of an unknown dataset" do
      expect(reason(DataTeller.ask("?", user: user_class.new(acme, [ :nobody ])))).to eq(:unknown_dataset)
      expect(reason(DataTeller.ask("?", user: user_class.new(acme, [])))).to eq(:unknown_dataset)
    end

    it "refuses a tenant whose time zone is broken: a wrong today is a wrong answer" do
      acme.update_column(:time_zone, "Mars/Olympus")

      expect(reason(DataTeller.ask("?", user: admin))).to eq(:unsupported_query)
    ensure
      acme.update_column(:time_zone, "Asia/Tokyo")
    end

    it "refuses when the engine is off" do
      allow(DataTeller).to receive(:enabled?).and_return(false)

      expect(reason(DataTeller.ask("?", user: admin))).to eq(:engine_disabled)
    end
  end

  it "says the assistant is unavailable with no adapter configured" do
    config = DataTeller.config.dup.tap { |copy| copy.llm = nil }
    allow(DataTeller).to receive(:config).and_return(config)

    expect(reason(DataTeller.ask("?", user: admin))).to eq(:llm_unavailable)
  end

  [ DataTeller::LLM::TimeoutError, DataTeller::LLM::RateLimited, DataTeller::LLM::Refused, DataTeller::LLM::InvalidResponse, DataTeller::LLM::SchemaTooLarge ].each do |error|
    it "turns #{error.name.demodulize} into one refusal, and logs the class only" do
      with_llm(adapter_class.new([ error.new("the model quoted: how many orders?") ], []))
      logged = []
      allow(Rails.logger).to receive(:error) { |message| logged << message }

      expect(reason(DataTeller.ask("how many orders?", user: admin))).to eq(:llm_unavailable)
      expect(logged).to eq([ "[DataTeller] the provider failed: #{error}" ])
    end
  end

  it "logs the cost, never the question" do
    with_llm(adapter_class.new([ count_orders ], []))
    logged = []
    allow(Rails.logger).to receive(:info) { |message| logged << message }

    DataTeller.ask("how much does jane.doe@example.com owe?", user: admin)

    expect(logged.join).to include("100 tokens in (40 cached), 10 out, 200 ms, whole catalog, fake")
    expect(logged.join).not_to include("jane.doe")
  end
end
