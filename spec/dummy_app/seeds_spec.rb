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

  it "keeps order totals consistent with their line items, discounts and refunds" do
    Order.includes(:line_items, :refunds).find_each do |order|
      expect(order.total_cents + order.discount_cents).to eq(order.line_items.sum { |li| li.quantity * li.unit_price_cents })
      expect(order.net_total_cents).to eq(order.total_cents - order.refunds.sum(&:amount_cents))
    end
  end

  # The evaluation needs rows behind every dataset: an empty one would make a wrong query look right.
  it "fills every table the evaluation domain declares" do
    [ Coupon, Refund, Subscription, Invoice, SupportTicket, Review, Shipment ].each do |model|
      expect(model.count).to be_positive, model.name
    end
    expect(Order.where.not(coupon_id: nil).count).to be_positive
  end

  it "gives each account one user per role" do
    expect(User.group(:account_id).count.values).to all(eq(3))
    expect(User.distinct.pluck(:role)).to contain_exactly("admin", "support", "member")
  end

  it "is deterministic" do
    first = Order.order(:id).pluck(:status, :total_cents)
    load Rails.root.join("db/seeds.rb")
    expect(Order.order(:id).pluck(:status, :total_cents)).to eq(first)
  end
end
