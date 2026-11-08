require "rails_helper"
require "tmpdir"

RSpec.describe DataTeller::Evaluation::Models::Routed do
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:out) { StringIO.new }
  let(:dev) { YAML.safe_load_file(Rails.root.join("eval/dev.yml")) }

  # Answers the expected query on the query call. On the router's call, routes well unless told otherwise for a question.
  let(:adapter_class) do
    Struct.new(:answers, :routes, :calls) do
      def model = "fake-model"
      def provider_schema(schema) = schema

      def complete(system:, user:, schema:)
        calls << { user: user, schema: schema }
        output = schema.dig("properties", "datasets") ? route(user, schema) : answers.fetch([ user, system[/Catalog for (\w+)\./, 1] ])
        DataTeller::LLM::Response.new(output: output, input_tokens: 100, output_tokens: 10, latency_ms: 5, model: "fake-model-2026")
      end

      private

      def route(user, schema)
        names = schema.dig("properties", "datasets", "items", "enum")
        { "datasets" => routes[user] || names.first(3) }
      end
    end
  end

  let(:answers) do
    dev["questions"].flat_map do |question|
      %w[en fr].map { |language| [ [ question[language], question.fetch("role", "admin") ], question["expected"] ] }
    end.to_h
  end

  before do
    FileUtils.mkdir_p(root.join("eval"))
    root.join("eval/dev.yml").write({ "today" => dev["today"], "tenant" => dev["tenant"], "questions" => questions }.to_yaml)
  end

  after { FileUtils.rm_rf(root) }

  def question(id) = dev["questions"].find { |candidate| candidate["id"] == id }

  def run_with(adapter, split: "dev", **options)
    config = DataTeller.config.dup.tap { |copy| copy.llm = adapter }
    allow(DataTeller).to receive(:config).and_return(config)
    DataTeller::Evaluation::Command.new(root: root, split: split, model: "routed", out: out, **options).call
  end

  context "with two questions expecting an answer and one refusal" do
    let(:questions) { [ question("net_revenue_last_month"), question("urgent_open_tickets"), question("weather") ] }
    let(:routes) do
      {
        question("net_revenue_last_month")["en"] => %w[orders refunds],
        question("net_revenue_last_month")["fr"] => %w[refunds orders customers],
        question("urgent_open_tickets")["en"] => %w[support_tickets],
        question("urgent_open_tickets")["fr"] => %w[customers orders]
      }
    end

    it "scores the router apart: within 1, 2 and 3 datasets, over the questions expecting an answer" do
      report = run_with(adapter_class.new(answers, routes, []))

      expect(report.summary["routing"]["within"]).to eq(
        "1" => { "right" => 2, "total" => 4, "percent" => 50.0 },
        "2" => { "right" => 3, "total" => 4, "percent" => 75.0 },
        "3" => { "right" => 3, "total" => 4, "percent" => 75.0 }
      )
      expect(report.summary["routing"]["missed"]).to eq([ "urgent_open_tickets/fr" ])
      expect(out.string).to include("Routing: within 1 50.0% (2/4), within 2 75.0% (3/4), within 3 75.0% (3/4)", "route missed: urgent_open_tickets/fr")
    end

    it "sends the query call the chosen datasets only, and adds up both calls" do
      adapter = adapter_class.new(answers, routes, [])

      report = run_with(adapter)

      first_query = adapter.calls.second
      expect(first_query[:schema]).to eq(DataTeller::SchemaGenerator.new(DataTeller::Catalog.for(:admin).only(%w[orders refunds])).call)
      expect(report.summary["usage"]).to include("input_tokens" => 1200, "output_tokens" => 120)
    end

    it "keeps the route in a saved run, and replays it" do
      run_with(adapter_class.new(answers, routes, []), save: true)
      file = root.join(out.string[/Saved: (.+)$/, 1])
      saved = JSON.parse(file.read)

      answer = saved["answers"].find { |entry| entry["id"] == "net_revenue_last_month" && entry["language"] == "fr" }
      expect(answer).to include("route" => %w[refunds orders customers], "route_rank" => 2)
      expect(saved["fingerprint"]).to eq("router #{DataTeller::Router.fingerprint} prompt #{DataTeller::Prompt.fingerprint}")

      replayed = DataTeller::Evaluation::Command.new(root: root, split: "dev", model: "replay", replay: file, out: StringIO.new).call
      expect(replayed.summary["routing"]).to eq(saved["summary"]["routing"])
    end

    it "keeps a held-out run to ranks and ids, no dataset names" do
      root.join("eval/held_out.yml").write(root.join("eval/dev.yml").read)

      report = run_with(adapter_class.new(answers, routes, []), split: "held_out")

      entry = report.to_h["answers"].find { |answer| answer["id"] == "net_revenue_last_month" && answer["language"] == "en" }
      expect(entry).to include("route_rank" => 1)
      expect(entry).not_to include("route", "output")
    end
  end

  context "with a question expecting a clarification" do
    let(:questions) { [ question("revenue_by_date") ] }

    it "has no right dataset to find" do
      report = run_with(adapter_class.new(answers, {}, []))

      expect(report.summary).not_to have_key("routing")
    end
  end

  context "when a call fails" do
    let(:questions) { [ question("urgent_open_tickets") ] }

    it "scores a model's failure as invalid output, and stops on anything else" do
      refused = adapter_class.new(answers, {}, [])
      allow(refused).to receive(:complete).and_raise(DataTeller::LLM::Refused, "no")
      expect(run_with(refused).summary["errors"]).to eq("invalid_output" => 2)

      broken = adapter_class.new(answers, {}, [])
      allow(broken).to receive(:complete).and_raise(DataTeller::LLM::ProviderError, "no")
      expect { run_with(broken) }.to raise_error(DataTeller::LLM::ProviderError)
    end
  end

  context "with no adapter" do
    let(:questions) { [ question("weather") ] }

    it "says so" do
      expect { run_with(nil) }.to raise_error(ArgumentError, "MODEL=routed needs c.llm in config/data_teller.rb (ADR 0008)")
    end
  end
end
