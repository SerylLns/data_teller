require "rails_helper"

RSpec.describe DataTeller::QuerySchema do
  fixtures_root = Rails.root.join("../fixtures/queries")

  describe "valid fixtures" do
    Dir[fixtures_root.join("valid/*.json")].each do |path|
      it "accepts #{File.basename(path, '.json')}" do
        query = JSON.parse(File.read(path))
        expect(described_class.errors(query)).to eq([])
      end
    end
  end

  describe "invalid fixtures" do
    Dir[fixtures_root.join("invalid/*.json")].each do |path|
      it "rejects #{File.basename(path, '.json')}" do
        query = JSON.parse(File.read(path))
        expect(described_class.valid?(query)).to be(false)
      end
    end
  end

  it "reports an infinite number as an error rather than raising" do
    query = { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "count", "limit" => Float::INFINITY }

    expect(described_class.valid?(query)).to be(false)
    expect(described_class.errors(query)).to eq([ { pointer: "", type: "not_finite" } ])
  end

  it "ships fixtures covering both sides" do
    expect(Dir[fixtures_root.join("valid/*.json")].size).to be >= 15
    expect(Dir[fixtures_root.join("invalid/*.json")].size).to be >= 15
  end
end
