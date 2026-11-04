require "rails_helper"

# Guards the fixtures every later eval and isolation spec relies on.
RSpec.describe "dummy app seeds" do
  before { load Rails.root.join("db/seeds.rb") }

  it "creates accounts of distinct sizes so a cross-tenant leak changes counts" do
    counts = Account.all.map { |a| a.orders.count }
    expect(counts.uniq.size).to eq(counts.size)
  end

  it "reaches the tenant through order for line items and shipments" do
    acme = Account.find_by!(name: "Acme")
    expect(LineItem.joins(:order).where(orders: { account_id: acme.id }).count).to be_positive
    expect(Shipment.joins(:order).where(orders: { account_id: acme.id }).count).to be_positive
  end

  it "keeps order totals consistent with their line items" do
    order = Order.includes(:line_items).first
    expect(order.total_cents).to eq(order.line_items.sum { |li| li.quantity * li.unit_price_cents })
  end

  it "is deterministic" do
    first = Order.order(:id).pluck(:status, :total_cents)
    load Rails.root.join("db/seeds.rb")
    expect(Order.order(:id).pluck(:status, :total_cents)).to eq(first)
  end
end
