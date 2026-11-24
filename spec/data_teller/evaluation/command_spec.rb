require "rails_helper"
require "tmpdir"

RSpec.describe DataTeller::Evaluation::Command do
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:out) { StringIO.new }
  let(:dev) { YAML.safe_load_file(Rails.root.join("eval/dev.yml")) }

  before { FileUtils.mkdir_p(root.join("eval")) }
  after { FileUtils.rm_rf(root) }

  def write_split(split, data = dev) = root.join("eval/#{split}.yml").write(data.to_yaml)
  def run(split = "dev", **options) = described_class.new(root: root, split: split, out: out, **options).call
  def answer(dataset, metric, **rest) = { "version" => 1, "intent" => "answer", "dataset" => dataset, "metric" => metric }.merge(rest.transform_keys(&:to_s))

  # A recorded run with three known mistakes, in English only.
  def replay_with_mistakes
    perfect = run("dev", save: true)
    file = root.join(out.string[/Saved: (.+)$/, 1])
    record = JSON.parse(file.read)
    mistakes = {
      "net_revenue_last_month" => answer("orders", "revenue", period: { "dimension" => "ordered_at", "range" => { "relative" => "last_month" } }),
      "gross_margin" => answer("orders", "revenue"),
      "customer_count" => "There are 25 customers."
    }
    record["answers"].each { |entry| entry["output"] = mistakes[entry["id"]] if entry["language"] == "en" && mistakes.key?(entry["id"]) }
    file.write(JSON.generate(record))
    expect(perfect.summary["score"]["percent"]).to eq(100.0)
    file
  end

  it "scores the perfect model at 100% on the working set, in both languages" do
    write_split("dev")

    report = run

    expect(report.summary["score"]).to eq("right" => 82, "total" => 82, "percent" => 100.0)
    expect(out.string).to include("Score: 100.0% (82/82)", "Errors: none")
  end

  it "replays a saved run, and classes each mistake" do
    write_split("dev")
    replay = replay_with_mistakes
    out.truncate(0)

    summary = run("dev", model: "replay", replay: replay.to_s).summary

    expect(summary["score"]).to eq("right" => 79, "total" => 82, "percent" => 96.3)
    expect(summary["by_language"]).to eq("en" => { "right" => 38, "total" => 41, "percent" => 92.7 }, "fr" => { "right" => 41, "total" => 41, "percent" => 100.0 })
    expect(summary["errors"]).to eq("answered_out_of_scope" => 1, "invalid_output" => 1, "wrong_answer" => 1)
    expect(summary["by_severity"]).to eq("high" => 2, "low" => 1)
    expect(out.string).to include("net_revenue_last_month/en: wrong_answer, differs on metric")
  end

  it "compares the rows of a wrong answer when the tenant is in the database" do
    load Rails.root.join("db/seeds.rb")
    write_split("dev")
    replay = replay_with_mistakes
    record = JSON.parse(replay.read)
    written_otherwise = answer("invoices", "invoiced", filters: [ { "dimension" => "status", "op" => "eq", "value" => "open" } ])
    record["answers"].find { |entry| entry["id"] == "unpaid_amount" && entry["language"] == "fr" }["output"] = written_otherwise
    replay.write(JSON.generate(record))

    summary = run("dev", model: "replay", replay: replay.to_s).summary

    expect(summary["to_review"]).to eq([ "unpaid_amount/fr" ])
  end

  describe "a held-out run" do
    before { write_split("held_out") }

    it "keeps no question text and no model output, in the report or in the saved run" do
      report = run("held_out", save: true)
      saved = root.join(out.string[/Saved: (.+)$/, 1]).read
      texts = dev["questions"].flat_map { |question| question.values_at("en", "fr") }

      expect(JSON.parse(saved)["answers"].flat_map(&:keys)).not_to include("output")
      texts.each do |text|
        expect(out.string).not_to include(text)
        expect(saved).not_to include(text)
      end
      expect(report.to_h["held_out"]).to be(true)
    end

    it "cannot be replayed, since it has nothing to replay" do
      run("held_out", save: true)

      expect { run("held_out", model: "replay", replay: root.join(out.string[/Saved: (.+)$/, 1]).to_s) }
        .to raise_error(ArgumentError, /held-out run/)
    end
  end

  # What a provider sends back is text: valid JSON is read as a query, anything else scores as invalid_output.
  it "reads an answer given as JSON text" do
    write_split("dev")
    replay = replay_with_mistakes
    record = JSON.parse(replay.read)
    record["answers"].each { |entry| entry["output"] = JSON.generate(entry["output"]) if entry["language"] == "fr" }
    replay.write(JSON.generate(record))

    expect(run("dev", model: "replay", replay: replay.to_s).summary["by_language"]["fr"]["percent"]).to eq(100.0)
  end

  it "runs one language when asked" do
    write_split("dev")

    expect(run(languages: [ "fr" ]).summary["by_language"].keys).to eq([ "fr" ])
  end

  it "says what is wrong with its arguments" do
    expect { run("nope") }.to raise_error(ArgumentError, /no question set/)
    write_split("dev")
    expect { run(model: "gpt") }.to raise_error(ArgumentError, /MODEL must be one of perfect, replay/)
    expect { run(model: "replay") }.to raise_error(ArgumentError, /REPLAY=/)
  end
end
