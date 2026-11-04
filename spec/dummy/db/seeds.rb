# FAKE DATA — development and test only. Deterministic (fixed RNG seed) so eval
# expectations stay stable. Never run against a real database.
abort("Refusing to seed fake data in production") if Rails.env.production?

rng = Random.new(42)
first_list = %w[Alice Bruno Chloé David Emma Farid Gaëlle Hugo Inès Jules Karim Léa Marc Nora Omar].freeze
last_list = %w[Dupont Martin Bernard Petit Robert Richard Durand Moreau Simon Laurent].freeze
cities_list = %w[Paris Lyon Marseille Lille Nantes Bordeaux].freeze
categories_list = { "Shoes" => 7_900, "Bags" => 12_900, "Hats" => 2_900, "Belts" => 3_900 }.freeze
carriers_list = %w[Colissimo DHL UPS].freeze

# Sizes differ per account so cross-tenant leaks change the counts visibly.
account_specs = [
  { name: "Acme", time_zone: "Europe/Paris", customers: 25, orders: 120 },
  { name: "Globex", time_zone: "America/New_York", customers: 12, orders: 50 },
  { name: "Initech", time_zone: "Asia/Tokyo", customers: 6, orders: 15 }
].freeze

ActiveRecord::Base.transaction do
  [ LineItem, Shipment, Order, Product, Customer, Account ].each(&:delete_all)

  account_specs.each do |spec|
    account = Account.create!(name: spec[:name], time_zone: spec[:time_zone])
    today = Time.use_zone(account.time_zone) { Time.zone.today }

    customers = Array.new(spec[:customers]) do |i|
      first = first_list.fetch(rng.rand(first_list.size))
      last = last_list.fetch(rng.rand(last_list.size))
      account.customers.create!(
        name: "#{first} #{last}",
        email: "#{first}.#{last}.#{i}@example.test".unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase,
        phone: "+33 6 00 00 #{format('%02d', i)} 00",
        city: cities_list.fetch(rng.rand(cities_list.size))
      )
    end

    products = categories_list.flat_map do |category, price|
      3.times.map { |n| account.products.create!(name: "#{category} #{n + 1}", category:, price_cents: price + n * 500) }
    end

    spec[:orders].times do
      status = Order.statuses.keys.fetch(rng.rand(Order.statuses.size))
      ordered_at = (today - rng.rand(0..90)).in_time_zone(account.time_zone) + rng.rand(0..86_399)
      order = account.orders.create!(
        customer: customers.fetch(rng.rand(customers.size)),
        status:, ordered_at:,
        ship_on: status == "paid" ? today + rng.rand(0..4) : ordered_at.to_date + rng.rand(1..3)
      )

      rng.rand(1..3).times do
        product = products.fetch(rng.rand(products.size))
        order.line_items.create!(product:, quantity: rng.rand(1..4), unit_price_cents: product.price_cents)
      end
      order.update!(total_cents: order.line_items.sum("quantity * unit_price_cents"))

      next unless %w[shipped delivered].include?(status)

      shipped_at = order.ship_on.in_time_zone(account.time_zone)
      order.shipments.create!(
        carrier: carriers_list.fetch(rng.rand(carriers_list.size)), shipped_at:,
        delivered_on: status == "delivered" ? order.ship_on + rng.rand(1..4) : nil
      )
    end
  end
end

puts "Seeded #{Account.count} accounts, #{Order.count} orders (FAKE DATA)" unless Rails.env.test?
