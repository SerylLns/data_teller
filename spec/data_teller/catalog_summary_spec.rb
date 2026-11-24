require "rails_helper"

RSpec.describe DataTeller::CatalogSummary do
  def summary(*roles) = described_class.new(DataTeller::Catalog.for(*roles)).call

  it "lists a role's datasets with their metrics, dates, fields and segments" do
    text = summary(:member)

    expect(text).to include("orders (order, purchase, sale, commande, achat, vente)")
    expect(text).to include("  metrics:  count (count)\n")
    expect(text).to include("ordered_at* (period, group by day..year)")
    expect(text).to include("status [pending|paid|shipped|delivered|cancelled] (filter, group)")
    expect(text).to include("  segments: paid, open, with_coupon")
  end

  # ADR 0016: where a list is accepted for the role, with the default columns it sees.
  it "says which datasets can be listed and their default columns" do
    expect(summary(:member)).to include("  list:     yes, default columns ordered_at, status, channel, ship_on\n")
    expect(summary(:admin).scan("  list:").size).to eq(1)
  end

  it "shows only what the role sees" do
    expect(summary(:member)).not_to include("revenue", "customers (", "invoices")
    expect(summary(:admin)).to include("revenue (sum total_cents, money)", "avg_basket (revenue / count)")
  end

  it "marks the dataset's own default date, not one reached through a path" do
    expect(summary(:member)).to include("published_on* (period", "product.launched_on (period")
  end

  it "says what a field cannot do" do
    expect(summary(:admin)).to include("customer.city [string] (filter)")
  end

  it "says when a role sees nothing" do
    expect(summary(:nobody)).to eq("No dataset is visible to nobody.\n")
  end
end
