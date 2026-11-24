require "rails_helper"
require "tmpdir"

RSpec.describe DataTeller::Evaluation::Models::Naive do
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:out) { StringIO.new }
  let(:dev) { YAML.safe_load_file(Rails.root.join("eval/dev.yml")) }

  # An adapter that answers what the file expects, or fails on the questions it is told to.
  let(:adapter_class) do
    Struct.new(:answers, :failures, :calls) do
      def model = "fake-model"
      def provider_schema(schema) = schema

      def complete(system:, user:, schema:)
        calls << { system: system, user: user, schema: schema }
        failure = failures[user]
        raise failure, "failed" if failure

        # The same text can be asked under two roles: the role is read from the prompt's catalog header.
        DataTeller::LLM::Response.new(output: answers.fetch([ user, system[/Catalog for (\w+)\./, 1] ]), input_tokens: 100, output_tokens: 10, latency_ms: 5,
                                      cached_input_tokens: 60, model: "fake-model-2026-11-01")
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
    root.join("eval/dev.yml").write(dev.to_yaml)
  end

  after { FileUtils.rm_rf(root) }

  def run_with(adapter, split: "dev", **options)
    # The published configuration is frozen: an unfrozen copy carries the adapter, the rest is the dummy's own.
    config = DataTeller.config.dup.tap { |copy| copy.llm = adapter }
    allow(DataTeller).to receive(:config).and_return(config)
    DataTeller::Evaluation::Command.new(root: root, split: split, model: "naive", out: out, **options).call
  end

  it "sends each question with the prompt and the schema of its role, and scores the answers" do
    adapter = adapter_class.new(answers, {}, [])

    report = run_with(adapter)

    expect(report.summary["score"]).to eq("right" => 82, "total" => 82, "percent" => 100.0)
    # Every answer was found under the role of its question (fetch above), with that role's schema.
    roles = adapter.calls.map { |entry| entry[:system][/Catalog for (\w+)\./, 1] }
    expect(roles.tally).to eq(dev["questions"].map { |question| question.fetch("role", "admin") }.tally.transform_values { |count| count * 2 })
    expect(adapter.calls.zip(roles)).to all(satisfy { |entry, role| entry[:schema] == DataTeller::SchemaGenerator.for_roles(role.to_sym) })
    expect(adapter.calls.map { |entry| entry[:system] }).to all(include("Today is #{dev['today']}"))
    expect(adapter.calls.map { |entry| entry[:system] }).to all(satisfy { |system| answers.keys.none? { |question, _role| system.include?(question) } })
  end

  it "reports the model answered with, the cached tokens and the prompt it measured" do
    report = run_with(adapter_class.new(answers, {}, []), save: true)

    expect(out.string).to include("model naive fake-model", "Tokens: 8200 in (4920 cached), 820 out", "Answered by: fake-model-2026-11-01")
    saved = JSON.parse(root.join(out.string[/Saved: (.+)$/, 1]).read)
    expect(saved["fingerprint"]).to eq("prompt #{DataTeller::Prompt.fingerprint}")
    expect(saved["answers"].first).to include("answered_by" => "fake-model-2026-11-01", "cached_input_tokens" => 60, "failure" => nil)
    expect(report.summary["usage"]).to include("answered_by" => [ "fake-model-2026-11-01" ], "failures" => {})
  end

  it "scores a model's failure to answer as invalid output, names its class, and goes on" do
    question = dev["questions"].first
    adapter = adapter_class.new(answers, { question["en"] => DataTeller::LLM::Refused }, [])

    report = run_with(adapter, save: true)

    expect(report.summary["errors"]).to eq("invalid_output" => 1)
    expect(out.string).to include("Failures: Refused 1")
    saved = JSON.parse(root.join(out.string[/Saved: (.+)$/, 1]).read)
    expect(saved["answers"].find { |answer| answer["id"] == question["id"] && answer["language"] == "en" })
      .to include("failure" => "Refused", "error" => "invalid_output", "output" => nil)
  end

  # A score with transport errors in it would measure the network, not the model.
  it "stops the run on anything else" do
    adapter = adapter_class.new(answers, { dev["questions"].first["en"] => DataTeller::LLM::ProviderError }, [])

    expect { run_with(adapter) }.to raise_error(DataTeller::LLM::ProviderError)
  end

  it "keeps a held-out run to ids, numbers and failure classes" do
    root.join("eval/held_out.yml").write(dev.to_yaml)
    adapter = adapter_class.new(answers, { dev["questions"].first["en"] => DataTeller::LLM::InvalidResponse }, [])

    report = run_with(adapter, split: "held_out")

    expect(report.to_h["answers"]).to all(satisfy { |answer| !answer.key?("output") })
    expect(report.to_h["answers"].map(&:keys).flatten.uniq).not_to include("text", "en", "fr")
  end

  it "needs an adapter in the configuration" do
    expect { run_with(nil) }.to raise_error(ArgumentError, "MODEL=naive needs c.llm in config/data_teller.rb (ADR 0008)")
  end
end
