# FAKE DATA — development and test only. Deterministic (fixed RNG seed) so eval
# expectations stay stable. Never run against a real database.
abort("Refusing to seed fake data in production") if Rails.env.production?

rng = Random.new(42)
pick = ->(list) { list.fetch(rng.rand(list.size)) }
# Weighted pick: { value => weight }.
weighted = lambda do |weights|
  roll = rng.rand(weights.values.sum)
  weights.each { |value, weight| return value if (roll -= weight).negative? }
end

first_list = %w[Alice Bruno Chloé David Emma Farid Gaëlle Hugo Inès Jules Karim Léa Marc Nora Omar].freeze
last_list = %w[Dupont Martin Bernard Petit Robert Richard Durand Moreau Simon Laurent].freeze
cities_list = %w[Paris Lyon Marseille Lille Nantes Bordeaux].freeze
categories_list = { "Shoes" => 7_900, "Bags" => 12_900, "Hats" => 2_900, "Belts" => 3_900 }.freeze
carriers_list = %w[Colissimo DHL UPS].freeze
plan_prices = { "starter" => 1_900, "pro" => 4_900, "business" => 14_900 }.freeze

# Sizes differ per account so cross-tenant leaks change the counts visibly.
account_specs = [
  { name: "Acme", time_zone: "Europe/Paris", customers: 25, orders: 120 },
  { name: "Globex", time_zone: "America/New_York", customers: 12, orders: 50 },
  { name: "Initech", time_zone: "Asia/Tokyo", customers: 6, orders: 15 }
].freeze

ActiveRecord::Base.transaction do
  [ User, Review, SupportTicket, Invoice, Subscription, Refund, LineItem, Shipment, Order, Coupon, Product, Customer, Account ].each(&:delete_all)

  account_specs.each do |spec|
    account = Account.create!(name: spec[:name], time_zone: spec[:time_zone])
    today = Time.use_zone(account.time_zone) { Time.zone.today }
    at = ->(day) { day.in_time_zone(account.time_zone) + rng.rand(0..86_399) }

    %w[admin support member].each do |role|
      account.users.create!(email: "#{role}@#{spec[:name].downcase}.example.test", role: role)
    end

    customers = Array.new(spec[:customers]) do |i|
      first = pick.(first_list)
      last = pick.(last_list)
      account.customers.create!(
        name: "#{first} #{last}",
        email: "#{first}.#{last}.#{i}@example.test".unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase,
        phone: "+33 6 00 00 #{format('%02d', i)} 00",
        city: pick.(cities_list),
        acquisition_channel: weighted.({ "organic" => 5, "ads" => 3, "referral" => 2, "marketplace" => 1 }),
        tier: weighted.({ "bronze" => 6, "silver" => 3, "gold" => 1 }),
        signed_up_on: today - rng.rand(30..720)
      )
    end

    products = categories_list.flat_map do |category, price|
      3.times.map do |n|
        account.products.create!(name: "#{category} #{n + 1}", category:, price_cents: price + n * 500,
                                 active: n < 2 || rng.rand < 0.5, launched_on: today - rng.rand(60..900))
      end
    end

    coupons = [
      account.coupons.create!(code: "WELCOME10", kind: "percent", value: 10, starts_on: today - 400),
      account.coupons.create!(code: "SUMMER20", kind: "percent", value: 20, starts_on: today - 150, ends_on: today - 60),
      account.coupons.create!(code: "FIVEOFF", kind: "fixed", value: 500, starts_on: today - 90),
      account.coupons.create!(code: "FREESHIP", kind: "free_shipping", value: 0, starts_on: today - 200)
    ]

    orders = Array.new(spec[:orders]) do
      status = pick.(Order.statuses.keys)
      ordered_at = at.(today - rng.rand(0..90))
      order = account.orders.create!(
        customer: pick.(customers), status:, ordered_at:,
        channel: weighted.({ "web" => 6, "mobile" => 3, "store" => 1 }),
        ship_on: status == "paid" ? today + rng.rand(0..4) : ordered_at.to_date + rng.rand(1..3)
      )

      rng.rand(1..3).times do
        product = pick.(products)
        order.line_items.create!(product:, quantity: rng.rand(1..4), unit_price_cents: product.price_cents)
      end

      gross = order.line_items.sum("quantity * unit_price_cents")
      coupon = rng.rand < 0.2 ? pick.(coupons) : nil
      discount =
        case coupon&.kind
        when "percent" then gross * coupon.value / 100
        when "fixed" then [ coupon.value, gross ].min
        else 0
        end
      order.update!(coupon:, discount_cents: discount, total_cents: gross - discount, net_total_cents: gross - discount)
      order
    end

    orders.each do |order|
      next unless %w[shipped delivered].include?(order.status)

      order.shipments.create!(
        carrier: pick.(carriers_list), shipped_at: order.ship_on.in_time_zone(account.time_zone),
        delivered_on: order.delivered? ? order.ship_on + rng.rand(1..4) : nil,
        cost_cents: order.coupon&.kind_free_shipping? ? 0 : rng.rand(400..1_200)
      )

      if rng.rand < 0.25
        amount = rng.rand < 0.5 ? order.total_cents : order.total_cents / 2
        order.refunds.create!(amount_cents: amount, reason: pick.(Refund.reasons.keys),
                              refunded_at: at.(order.ship_on + rng.rand(3..20)).then { |time| [ time, Time.current ].min })
        order.update!(net_total_cents: order.total_cents - amount)
      end

      next unless order.delivered? && rng.rand < 0.35

      product = order.line_items.first.product
      product.reviews.create!(customer: order.customer, rating: weighted.({ 5 => 5, 4 => 3, 3 => 1, 2 => 1, 1 => 1 }),
                              verified: true, published_on: [ order.ship_on + rng.rand(5..15), today ].min)
    end

    # A few reviews from people who did not buy: unverified.
    (spec[:customers] / 4).times do
      pick.(products).reviews.create!(customer: pick.(customers), rating: rng.rand(1..5), verified: false,
                                      published_on: today - rng.rand(0..120))
    end

    customers.select { rng.rand < 0.4 }.each.with_index(1) do |customer, n|
      plan = weighted.({ "starter" => 5, "pro" => 3, "business" => 1 })
      started_on = today - rng.rand(10..400)
      status = weighted.({ "active" => 6, "trialing" => 1, "past_due" => 1, "cancelled" => 2 })
      cancelled_on = status == "cancelled" ? [ started_on + rng.rand(30..200), today ].min : nil
      subscription = account.subscriptions.create!(customer:, plan:, status:, mrr_cents: plan_prices.fetch(plan), started_on:, cancelled_on:)
      next if status == "trialing"

      # Monthly invoices from the start to today, or to the cancellation.
      issued_on = started_on
      month = 0
      while issued_on <= (cancelled_on || today)
        month += 1
        due_on = issued_on + 14
        status =
          if due_on > today && rng.rand < 0.7 then "open"
          elsif subscription.status_past_due? && issued_on > today - 45 then "open"
          elsif rng.rand < 0.04 then "void"
          else "paid"
          end
        account.invoices.create!(
          customer:, subscription:, number: "#{spec[:name][0, 3].upcase}-#{format('%04d', n)}-#{format('%02d', month)}",
          status:, amount_cents: subscription.mrr_cents, issued_on:, due_on:,
          paid_at: status == "paid" ? [ at.(issued_on + rng.rand(0..20)), Time.current ].min : nil
        )
        issued_on = issued_on.next_month
      end
    end

    (spec[:customers] * 3 / 2).times do
      customer = pick.(customers)
      opened_at = at.(today - rng.rand(0..90))
      status = weighted.({ "open" => 2, "pending" => 2, "solved" => 3, "closed" => 4 })
      resolved = %w[solved closed].include?(status)
      minutes = resolved ? rng.rand(15..4_320) : nil
      account.support_tickets.create!(
        customer:, order: rng.rand < 0.6 ? customer.orders.first : nil,
        channel: weighted.({ "email" => 5, "chat" => 3, "phone" => 2 }),
        priority: weighted.({ "low" => 3, "normal" => 5, "high" => 2, "urgent" => 1 }),
        status:, opened_at:,
        resolved_at: resolved ? [ opened_at + minutes.minutes, Time.current ].min : nil,
        resolution_minutes: minutes,
        satisfaction: status == "closed" && rng.rand < 0.7 ? weighted.({ 5 => 4, 4 => 3, 3 => 2, 2 => 1, 1 => 1 }) : nil
      )
    end
  end
end

puts "Seeded #{Account.count} accounts, #{Order.count} orders, #{Invoice.count} invoices, #{SupportTicket.count} tickets (FAKE DATA)" unless Rails.env.test?
