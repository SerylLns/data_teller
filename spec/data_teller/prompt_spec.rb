require "rails_helper"

RSpec.describe DataTeller::Prompt do
  let(:paris) { ActiveSupport::TimeZone["Europe/Paris"] }

  def system(role) = described_class.new(DataTeller::Catalog.for(role), today: Date.new(2026, 11, 4), time_zone: paris).system

  it "gives today in the tenant's time zone and the role's catalog as text" do
    text = system(:admin)

    expect(text).to include("Today is 2026-11-04 (Europe/Paris).")
    expect(text).to include(DataTeller::CatalogSummary.new(DataTeller::Catalog.for(:admin)).call.chomp)
  end

  # The prompt must not tell a role what it cannot ask for (ADR 0001 D5): the catalog in it is the role's own.
  it "shows a role its own catalog only" do
    text = system(:member)

    expect(text).to include("Catalog for member.", "orders (", "reviews (")
    expect(text).not_to include("customers (", "refunds (", "invoices (", "revenue", "net_revenue")
  end

  it "holds the rules and the catalog, never a question" do
    expect(described_class.instance_method(:initialize).parameters.map(&:last)).to eq(%i[catalog today time_zone])
  end

  it "names its template, so that a saved run says which prompt it measured" do
    expect(described_class.fingerprint).to match(/\A\h{12}\z/)
    expect(described_class.fingerprint).to eq(Digest::SHA256.hexdigest(described_class::TEMPLATE)[0, 12])
  end
end
