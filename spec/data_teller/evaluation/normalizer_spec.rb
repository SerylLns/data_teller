require "rails_helper"

RSpec.describe DataTeller::Evaluation::Normalizer do
  subject(:normalizer) do
    described_class.new(catalog: DataTeller::Catalog.for(:admin), today: Date.new(2026, 11, 4), time_zone: ActiveSupport::TimeZone["Europe/Paris"])
  end

  def answer(**rest) = { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "revenue" }.merge(rest.transform_keys(&:to_s))
  def same?(left, right) = normalizer.call(left) == normalizer.call(right)
  def status(op, value) = { "dimension" => "status", "op" => op, "value" => value }

  # ADR 0016.
  describe "lists" do
    def list(**rest) = { "version" => 1, "intent" => "answer", "dataset" => "orders", "list" => true }.merge(rest.transform_keys(&:to_s))
    def by(dimension, dir) = { "by" => "dimension", "dimension" => dimension, "dir" => dir }

    it "reads no columns as the defaults, and columns as a set" do
      expect(same?(list, list(columns: %w[ship_on channel status ordered_at]))).to be(true)
      expect(same?(list(columns: %w[status ordered_at]), list(columns: %w[ordered_at status]))).to be(true)
      expect(same?(list, list(columns: %w[ordered_at status]))).to be(false)
    end

    it "ignores the order without a limit, and reads the default order with one" do
      expect(same?(list(order_by: by("status", "asc")), list)).to be(true)
      expect(same?(list(limit: 10), list(limit: 10, order_by: by("ordered_at", "desc")))).to be(true)
      expect(same?(list(limit: 10), list(limit: 10, order_by: by("ordered_at", "asc")))).to be(false)
    end

    it "is never the same as a metric" do
      expect(same?(list, answer(metric: "count"))).to be(false)
    end
  end

  it "ignores the order of filters and of groups" do
    expect(same?(answer(filters: [ { "segment" => "paid" }, status("eq", "paid") ]), answer(filters: [ status("eq", "paid"), { "segment" => "paid" } ]))).to be(true)
    expect(same?(answer(group_by: [ { "dimension" => "status" }, { "dimension" => "channel" } ]),
                 answer(group_by: [ { "dimension" => "channel" }, { "dimension" => "status" } ]))).to be(true)
  end

  it "reads in and not_in with one value as eq and not_eq, and a list as a set" do
    expect(same?(answer(filters: [ status("in", [ "paid" ]) ]), answer(filters: [ status("eq", "paid") ]))).to be(true)
    expect(same?(answer(filters: [ status("not_in", [ "paid" ]) ]), answer(filters: [ status("not_eq", "paid") ]))).to be(true)
    expect(same?(answer(filters: [ status("in", %w[paid shipped]) ]), answer(filters: [ status("in", %w[shipped paid]) ]))).to be(true)
  end

  it "compares periods by the dates they resolve to on the day of the questions" do
    october = { "dimension" => "ordered_at", "range" => { "between" => { "from" => "2026-10-01", "to" => "2026-10-31" } } }
    last_month = { "dimension" => "ordered_at", "range" => { "relative" => "last_month" } }

    expect(same?(answer(period: october), answer(period: last_month))).to be(true)
    expect(same?(answer(period: last_month), answer(period: last_month.merge("dimension" => "ship_on")))).to be(false)
    expect(same?(answer(period: last_month), answer(period: { "dimension" => "ordered_at", "range" => { "relative" => "this_month" } }))).to be(false)
  end

  describe "order_by" do
    let(:by_customer) { { group_by: [ { "dimension" => "customer.name" } ] } }
    let(:by_status) { { group_by: [ { "dimension" => "status" } ] } }

    it "drops the one the compiler applies anyway to a high-cardinality group" do
      expect(same?(answer(**by_customer, order_by: { "by" => "metric", "dir" => "desc" }), answer(**by_customer))).to be(true)
      expect(same?(answer(**by_customer, order_by: { "by" => "metric", "dir" => "asc" }), answer(**by_customer))).to be(false)
    end

    it "drops one that only orders rows nothing cuts, and keeps one that decides what a limit keeps" do
      expect(same?(answer(**by_status, order_by: { "by" => "metric", "dir" => "asc" }), answer(**by_status))).to be(true)
      expect(same?(answer(**by_status, order_by: { "by" => "metric", "dir" => "desc" }, limit: 2), answer(**by_status, limit: 2))).to be(false)
    end
  end

  it "keeps everything else as written: dataset, metric, values, limit, compare" do
    expect(same?(answer, answer(metric: "net_revenue"))).to be(false)
    expect(same?(answer(filters: [ status("eq", "paid") ]), answer(filters: [ status("eq", "Paid") ]))).to be(false)
    expect(same?(answer(group_by: [ { "dimension" => "customer.name" } ], limit: 5), answer(group_by: [ { "dimension" => "customer.name" } ], limit: 10))).to be(false)
  end

  it "reads clarification options as a set, and out_of_scope by its reason" do
    clarify = ->(options) { { "version" => 1, "intent" => "clarify", "clarify" => { "reason" => "ambiguous_dimension", "options" => options } } }

    expect(same?(clarify.(%w[ordered_at ship_on]), clarify.(%w[ship_on ordered_at]))).to be(true)
    expect(normalizer.call({ "version" => 1, "intent" => "out_of_scope", "out_of_scope" => { "reason" => "unknown_metric" } }))
      .to eq("intent" => "out_of_scope", "reason" => "unknown_metric")
  end
end
