require "rails_helper"

RSpec.describe DataTeller::Pipeline do
  let(:admin) { DataTeller::Catalog.for(:admin) }
  let(:paris) { ActiveSupport::TimeZone["Europe/Paris"] }
  let(:query) { { "version" => 1, "intent" => "answer", "dataset" => "refunds", "metric" => "count" } }
  let(:adapter_class) do
    Struct.new(:answers, :calls) do
      def provider_schema(schema) = schema

      def complete(system:, user:, schema:)
        calls << { system: system, user: user, schema: schema }
        DataTeller::LLM::Response.new(output: answers.shift, input_tokens: 100, cached_input_tokens: 40, output_tokens: 10, latency_ms: 200, model: "fake-2026")
      end
    end
  end

  def run(question = "how many refunds?", catalog: admin, **llms) = described_class.new(**llms).call(question, catalog: catalog, today: Date.new(2026, 11, 4), time_zone: paris)

  it "routes, then writes the query against the datasets chosen only" do
    llm = adapter_class.new([ { "datasets" => %w[refunds orders] }, query ], [])

    result = run(llm: llm)

    expect(result.output).to eq(query)
    expect(result.route).to eq(%w[refunds orders])
    second = llm.calls.last
    expect(second[:schema]).to eq(DataTeller::SchemaGenerator.new(admin.only(%w[refunds orders])).call)
    expect(second[:system]).to include("Today is 2026-11-04 (Europe/Paris).", "refunds (", "orders (")
    expect(second[:system]).not_to include("invoices (", "subscriptions (")
    expect(second[:user]).to eq("how many refunds?")
  end

  it "adds up both calls" do
    result = run(llm: adapter_class.new([ { "datasets" => %w[refunds] }, query ], []))

    expect(result).to have_attributes(input_tokens: 200, cached_input_tokens: 80, output_tokens: 20, latency_ms: 400, model: "fake-2026")
  end

  it "uses the router's adapter for the first call only" do
    router = adapter_class.new([ { "datasets" => %w[refunds] } ], [])
    llm = adapter_class.new([ query ], [])

    run(llm: llm, router_llm: router)

    expect(router.calls.size).to eq(1)
    expect(llm.calls.size).to eq(1)
  end

  it "stays within the role's catalog: narrowing never adds a dataset" do
    llm = adapter_class.new([ { "datasets" => %w[refunds] }, query ], [])

    run(catalog: DataTeller::Catalog.for(:support), llm: llm)

    expect(llm.calls.last[:system]).to include("Catalog for support.")
    expect(llm.calls.last[:system]).not_to include("revenue", "invoices")
  end
end
