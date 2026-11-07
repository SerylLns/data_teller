require "rails_helper"

RSpec.describe DataTeller::SchemaGenerator do
  def schema_for(*roles) = described_class.for_roles(roles)
  def schemer_for(*roles) = JSONSchemer.schema(schema_for(*roles), regexp_resolver: "ecma")

  def answer(dataset, metric = "count", **rest)
    { "version" => 1, "intent" => "answer", "dataset" => dataset, "metric" => metric }.merge(rest.transform_keys(&:to_s))
  end

  def on_date(dimension) = { "dimension" => dimension, "range" => { "relative" => "tomorrow" } }
  def equals(dimension) = { "dimension" => dimension, "op" => "eq", "value" => "x" }

  let(:admin) { schemer_for(:admin) }
  let(:support) { schemer_for(:support) }

  it "produces one branch per visible dataset, plus clarify and out_of_scope" do
    expect(schema_for(:admin)["anyOf"].size).to eq(DataTeller::Catalog.for(:admin).datasets.size + 2)
  end

  describe "datasets and metrics" do
    it "accepts a metric in its own dataset" do
      expect(admin.valid?(answer("orders", "revenue"))).to be(true)
      expect(admin.valid?(answer("customers", "count"))).to be(true)
    end

    # The whole point of ADR 0004 D8.
    it "cannot express a metric of another dataset" do
      expect(admin.valid?(answer("customers", "revenue"))).to be(false)
    end

    it "cannot express an unknown dataset or metric" do
      expect(admin.valid?(answer("quotes"))).to be(false)
      expect(admin.valid?(answer("orders", "margin"))).to be(false)
    end

    it "leaves forbidden names out for a role" do
      expect(support.valid?(answer("orders", "revenue"))).to be(false)
      expect(support.valid?(answer("orders", "avg_basket"))).to be(false)
      expect(support.valid?(answer("orders", "count"))).to be(true)
      expect(schema_for(:support).to_json).not_to include("revenue", "avg_basket")
    end
  end

  describe "period" do
    it "accepts date dimensions" do
      expect(admin.valid?(answer("orders", period: on_date("ship_on")))).to be(true)
    end

    it "refuses anything else" do
      expect(admin.valid?(answer("orders", period: on_date("status")))).to be(false)
    end

    it "disappears, with compare, from a dataset without date dimensions" do
      expect(admin.valid?(answer("customers", period: on_date("city")))).to be(false)
      expect(admin.valid?(answer("customers", period: on_date("city"), compare: "previous_year"))).to be(false)
    end
  end

  describe "filters" do
    it "accepts a declared dimension and a path" do
      expect(admin.valid?(answer("orders", filters: [ equals("status"), equals("customer.city") ]))).to be(true)
    end

    it "refuses date dimensions: time goes through period (ADR 0001 D1)" do
      expect(admin.valid?(answer("orders", filters: [ equals("ship_on") ]))).to be(false)
    end

    it "refuses a path that does not exist from this dataset" do
      expect(admin.valid?(answer("customers", filters: [ equals("customer.city") ]))).to be(false)
    end

    it "refuses a column that is not declared" do
      expect(admin.valid?(answer("customers", filters: [ equals("email") ]))).to be(false)
      expect(admin.valid?(answer("orders", filters: [ equals("customer.email") ]))).to be(false)
    end

    it "accepts a declared segment only" do
      expect(admin.valid?(answer("orders", filters: [ { "segment" => "paid" } ]))).to be(true)
      expect(admin.valid?(answer("orders", filters: [ { "segment" => "nope" } ]))).to be(false)
      expect(admin.valid?(answer("customers", filters: [ { "segment" => "paid" } ]))).to be(false)
    end

    it "keeps the operator rules of the base schema" do
      expect(admin.valid?(answer("orders", filters: [ { "dimension" => "status", "op" => "in", "value" => "x" } ]))).to be(false)
    end
  end

  describe "group_by (ADR 0004 D3)" do
    def grouped(dataset, dimension) = answer(dataset, group_by: [ { "dimension" => dimension } ])

    it "allows enums and dates by default" do
      expect(admin.valid?(grouped("orders", "status"))).to be(true)
      expect(admin.valid?(grouped("orders", "ordered_at"))).to be(true)
    end

    it "refuses a free string by default: grouping by it would list rows" do
      expect(admin.valid?(grouped("customers", "city"))).to be(false)
      expect(admin.valid?(grouped("orders", "customer.city"))).to be(false)
    end

    it "allows it with an explicit group: true" do
      expect(admin.valid?(grouped("customers", "name"))).to be(true)
      expect(admin.valid?(grouped("orders", "customer.name"))).to be(true)
    end

    it "uses the same names in order_by" do
      ordered = { "by" => "dimension", "dimension" => "city", "dir" => "asc" }
      expect(admin.valid?(answer("customers", order_by: ordered))).to be(false)
      expect(admin.valid?(answer("customers", order_by: ordered.merge("dimension" => "name")))).to be(true)
      expect(admin.valid?(answer("customers", order_by: { "by" => "metric", "dir" => "desc" }))).to be(true)
    end
  end

  describe "clarify" do
    def clarify(*options) = { "version" => 1, "intent" => "clarify", "clarify" => { "reason" => "ambiguous_metric", "options" => options } }

    it "only offers names the role can see" do
      expect(admin.valid?(clarify("revenue", "count"))).to be(true)
      expect(support.valid?(clarify("revenue", "count"))).to be(false)
    end
  end

  describe "out_of_scope" do
    let(:refusal) { { "version" => 1, "intent" => "out_of_scope", "out_of_scope" => { "reason" => "unknown_metric" } } }

    it "is always possible" do
      expect(admin.valid?(refusal)).to be(true)
    end

    it "is all that is left without a role" do
      nobody = schemer_for

      expect(nobody.valid?(refusal)).to be(true)
      expect(nobody.valid?(answer("orders"))).to be(false)
      expect(schema_for.to_json).not_to include("orders")
    end
  end

  # The generated schema narrows the base one, it must never allow something the base refuses.
  it "only accepts what the base schema accepts" do
    samples = [
      answer("orders", "revenue", period: on_date("ordered_at"), compare: "previous_period",
             filters: [ equals("customer.city"), { "segment" => "open" } ], group_by: [ { "dimension" => "status" } ],
             order_by: { "by" => "metric", "dir" => "desc" }, limit: 5),
      answer("customers")
    ]

    samples.each do |query|
      expect(admin.valid?(query)).to be(true)
      expect(DataTeller::QuerySchema.valid?(query)).to be(true)
    end
  end

  it "rejects every invalid fixture of the base schema" do
    Dir[Rails.root.join("../fixtures/queries/invalid/*.json")].each do |path|
      expect(admin.valid?(JSON.parse(File.read(path)))).to be(false), "accepted #{File.basename(path)}"
    end
  end

  it "is a closed engine's empty answer when nothing is published" do
    DataTeller.reset!

    expect(schemer_for(:admin).valid?(answer("orders"))).to be(false)
  ensure
    DataTeller.boot!(Rails.root)
  end
end
