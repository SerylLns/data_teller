# customer.city and customer.name are never written here: the paths come from the Customer declaration (ADR 0001 D4).
DataTeller.refine Order do
  roles :admin, :support, :member
  tenant_path :account
  synonyms "order", "purchase", "sale", "commande", "achat", "vente"

  metric :revenue, sum: :total_cents, format: :money, roles: :admin   # support sees volumes, not revenue
  metric :net_revenue, sum: :net_total_cents, format: :money, roles: :admin
  metric :discounts, sum: :discount_cents, format: :money, roles: :admin
  metric :avg_basket, ratio: %i[revenue count]                        # visible only to roles that see revenue
  metric :customers, count_distinct: :customer_id, roles: %i[admin support]

  dimension :ordered_at, time: true                                   # default time dimension
  dimension :ship_on                                                  # a second date: "tomorrow" stays ambiguous
  dimension :status
  dimension :channel

  # Listed row by row by any role; customer.city is there to ask for, refused to support by the customers' min_group_size (ADR 0016).
  list default: %i[ordered_at status channel ship_on]

  segment :paid, where: { status: :paid }
  segment :open, where: { status: %i[pending paid] }
  segment :with_coupon, scope: :with_coupon, roles: %i[admin support member]
end
