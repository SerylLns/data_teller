require "rails_helper"

RSpec.describe DataTeller::Router do
  let(:adapter_class) do
    Struct.new(:output, :calls) do
      def provider_schema(schema) = schema

      def complete(system:, user:, schema:)
        calls << { system: system, user: user, schema: schema }
        DataTeller::LLM::Response.new(output: output, input_tokens: 90, cached_input_tokens: 50, output_tokens: 8, latency_ms: 300)
      end
    end
  end
  let(:admin) { DataTeller::Catalog.for(:admin) }

  def adapter(output) = adapter_class.new(output, [])

  it "asks with the index and the question apart, and gives back the datasets in the order chosen" do
    llm = adapter("datasets" => %w[refunds orders])

    route = described_class.new(llm, admin).call("how much was refunded?")

    expect(route).to have_attributes(datasets: %w[refunds orders], input_tokens: 90, cached_input_tokens: 50, output_tokens: 8, latency_ms: 300)
    expect(llm.calls.first[:user]).to eq("how much was refunded?")
    expect(llm.calls.first[:system]).not_to include("how much was refunded?")
  end

  it "shows datasets, synonyms and metric names, not fields (ADR 0007 D3)" do
    index = described_class.new(adapter({}), admin).index

    expect(index).to include("orders (order, purchase, sale, commande, achat, vente): metrics count, revenue, net_revenue")
    expect(index).not_to include("ordered_at", "status")
  end

  # The catalog in the router is the role's: it must not reveal, nor be able to name, what the role cannot see.
  it "only knows the role's datasets and metrics" do
    router = described_class.new(adapter({}), DataTeller::Catalog.for(:member))

    expect(router.index).not_to include("customers (", "invoices", "revenue")
    expect(router.schema.dig("properties", "datasets", "items", "enum")).to contain_exactly("line_items", "orders", "products", "reviews")
  end

  it "asks for one to three datasets, whatever the catalog's size" do
    expect(described_class.new(adapter({}), admin).schema.dig("properties", "datasets")).to include("minItems" => 1, "maxItems" => 3)
  end

  it "judges the answer itself: an adapter may not enforce the schema" do
    route = described_class.new(adapter("datasets" => %w[orders invoices orders refunds customers products]), DataTeller::Catalog.for(:support)).call("?")

    expect(route.datasets).to eq(%w[orders refunds customers])
  end

  [ { "datasets" => %w[invoices] }, { "datasets" => [] }, {}, "orders" ].each do |output|
    it "refuses an answer that names no dataset of the catalog: #{output.inspect}" do
      expect { described_class.new(adapter(output), DataTeller::Catalog.for(:support)).call("?") }.to raise_error(DataTeller::LLM::InvalidResponse)
    end
  end

  it "makes no call when there is nothing to narrow" do
    llm = adapter("datasets" => [])
    small = DataTeller::Catalog.for(:admin).only(%w[orders refunds])

    route = described_class.new(llm, small).call("?")

    expect(route.datasets).to contain_exactly("orders", "refunds")
    expect(llm.calls).to be_empty
    expect(described_class.new(llm, DataTeller::Catalog.for(:nobody)).call("?").datasets).to eq([])
    expect(llm.calls).to be_empty
  end

  it "leaves out a dataset with no visible metric: it has no branch in the query schema" do
    entries = admin.datasets
    without_metrics = entries.first.with(metrics: [])
    catalog = instance_double(DataTeller::Catalog, datasets: [ without_metrics, *entries.drop(1) ])

    expect(described_class.new(adapter({}), catalog).schema.dig("properties", "datasets", "items", "enum")).not_to include(without_metrics.name.to_s)
  end

  it "names its template" do
    expect(described_class.fingerprint).to match(/\A\h{12}\z/)
  end
end
