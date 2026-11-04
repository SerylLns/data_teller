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

  it "ships fixtures covering both sides" do
    expect(Dir[fixtures_root.join("valid/*.json")].size).to be >= 15
    expect(Dir[fixtures_root.join("invalid/*.json")].size).to be >= 15
  end
end
