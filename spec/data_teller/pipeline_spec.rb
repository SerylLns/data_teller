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

  # Routing forced, unless a test says otherwise: the dummy's catalog is under the default threshold.
  def run(question = "how many refunds?", catalog: admin, route_above: 0, **llms)
    described_class.new(route_above: route_above, **llms).call(question, catalog: catalog, today: Date.new(2026, 11, 4), time_zone: paris)
  end

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

  context "with a catalog up to the threshold (ADR 0007 D6)" do
    it "sends the whole catalog in one call, with no router" do
      llm = adapter_class.new([ query ], [])

      result = run(route_above: 11, llm: llm)

      expect(llm.calls.size).to eq(1)
      expect(llm.calls.first[:schema]).to eq(DataTeller::SchemaGenerator.new(admin).call)
      expect(result).to have_attributes(output: query, route: nil, input_tokens: 100, cached_input_tokens: 40, output_tokens: 10, latency_ms: 200)
    end

    it "routes one dataset beyond it" do
      llm = adapter_class.new([ { "datasets" => %w[refunds] }, query ], [])

      expect(run(route_above: 10, llm: llm).route).to eq(%w[refunds])
      expect(llm.calls.size).to eq(2)
    end

    it "counts what the role sees, not what the app declares" do
      llm = adapter_class.new([ query ], [])

      run(route_above: 8, catalog: DataTeller::Catalog.for(:support), llm: llm)

      expect(llm.calls.size).to eq(1)
    end

    it "takes its default from the configuration" do
      llm = adapter_class.new([ query ], [])

      expect(DataTeller.config.route_above_datasets).to eq(12)
      described_class.new(llm: llm).call("?", catalog: admin, today: Date.new(2026, 11, 4), time_zone: paris)

      expect(llm.calls.size).to eq(1)
    end
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
