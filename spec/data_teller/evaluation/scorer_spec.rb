require "rails_helper"

RSpec.describe DataTeller::Evaluation::Scorer do
  let(:set) { DataTeller::Evaluation::QuestionSet.load(Rails.root.join("eval/dev.yml")) }
  let(:time_zone) { ActiveSupport::TimeZone["Europe/Paris"] }
  let(:scorer) { described_class.new(today: set.today, time_zone: time_zone) }

  def question(id) = set.questions.find { |candidate| candidate.id == id }
  def answer(dataset, metric, **rest) = { "version" => 1, "intent" => "answer", "dataset" => dataset, "metric" => metric }.merge(rest.transform_keys(&:to_s))
  def clarify(reason, options) = { "version" => 1, "intent" => "clarify", "clarify" => { "reason" => reason, "options" => options } }
  def out_of_scope(reason) = { "version" => 1, "intent" => "out_of_scope", "out_of_scope" => { "reason" => reason } }

  # The calibration the whole eval rests on: a model that answers what the file expects scores 100%.
  it "scores every expected and accepted query of the working set as right" do
    set.questions.each do |one|
      one.accepted.each { |query| expect(scorer.call(one, query)).to have_attributes(correct: true, error: nil), one.id }
    end
  end

  it "names the fields a wrong answer got wrong" do
    wrong = answer("orders", "revenue", period: { "dimension" => "ship_on", "range" => { "relative" => "last_month" } })

    expect(scorer.call(question("net_revenue_last_month"), wrong))
      .to have_attributes(correct: false, error: :wrong_answer, severity: :high,
                          fields: a_hash_including(dataset: true, metric: false, period: false, filters: true))
  end

  {
    "an answer for another answer" => [ "revenue_last_month", -> { answer("orders", "net_revenue", period: { "dimension" => "ordered_at", "range" => { "relative" => "last_month" } }) }, :wrong_answer, :high ],
    "an answer to what is out of scope" => [ "gross_margin", -> { answer("orders", "revenue") }, :answered_out_of_scope, :high ],
    "a clarification where the question was clear" => [ "customer_count", -> { clarify("ambiguous_dataset", %w[customers orders]) }, :unnecessary_clarification, :medium ],
    "an answer where a clarification was due" => [ "revenue_by_date", -> { answer("orders", "revenue", group_by: [ { "dimension" => "ordered_at", "granularity" => "day" } ]) }, :missed_clarification, :medium ],
    "a clarification of what is out of scope" => [ "gross_margin", -> { clarify("ambiguous_metric", %w[revenue net_revenue]) }, :clarified_out_of_scope, :medium ],
    "the wrong options" => [ "revenue_by_date", -> { clarify("ambiguous_dimension", %w[ordered_at customer.signed_up_on]) }, :wrong_clarification, :low ],
    "a refusal of an answerable question" => [ "customer_count", -> { out_of_scope("unknown_dataset") }, :wrongful_refusal, :low ],
    "the wrong reason" => [ "employees", -> { out_of_scope("unknown_metric") }, :wrong_reason, :low ],
    "a query the validator refuses" => [ "customer_count", -> { answer("customers", "revenue") }, :invalid_output, :low ],
    "something that is not a query" => [ "customer_count", -> { "42 customers" }, :invalid_output, :low ]
  }.each do |label, (id, output, error, severity)|
    it "classes #{label} as #{error}, #{severity}" do
      expect(scorer.call(question(id), instance_exec(&output))).to have_attributes(correct: false, error: error, severity: severity)
    end
  end

  # A name the role does not see is as invalid as a name that does not exist: support has no revenue.
  it "judges a query with the question's role" do
    expect(scorer.call(question("revenue_as_support"), answer("orders", "revenue"))).to have_attributes(error: :invalid_output)
  end

  it "keeps the question's text and the output out of the score" do
    score = scorer.call(question("customer_count"), answer("orders", "customers"))

    expect(score.to_h.values.flatten.map(&:to_s).join(" ")).not_to include("How many", "Combien", "orders")
  end

  describe "same_result, on the seeds" do
    let(:executor) do
      DataTeller::Evaluation::Executor.new(tenant: Account.find_by!(name: set.tenant), today: set.today, time_zone: time_zone)
    end
    let(:scorer) { described_class.new(today: set.today, time_zone: time_zone, executor: executor) }

    before { load Rails.root.join("db/seeds.rb") }

    # status = paid is what the segment paid means, written another way: the same rows, so a missing also_accepted to review.
    it "flags a wrong answer that returns the rows of an accepted one" do
      paid = answer("invoices", "count", filters: [ { "dimension" => "status", "op" => "eq", "value" => "open" } ])
      unpaid = question("unpaid_amount")
      written_otherwise = answer("invoices", "invoiced", filters: [ { "dimension" => "status", "op" => "eq", "value" => "open" } ])

      expect(scorer.call(unpaid, written_otherwise)).to have_attributes(error: :wrong_answer, same_result: true)
      expect(scorer.call(unpaid, paid)).to have_attributes(error: :wrong_answer, same_result: false)
    end

    it "is not checked for anything but a wrong answer" do
      expect(scorer.call(question("customer_count"), out_of_scope("unknown_dataset")).same_result).to be_nil
    end
  end
end
