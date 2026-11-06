# customer.city and customer.name are never written here: the paths come from the Customer declaration (ADR 0001 D4).
DataTeller.refine Order do
  roles :admin, :support
  tenant_path :account
  synonyms "commande", "order"

  metric :revenue, sum: :total_cents, format: :money, roles: :admin   # support sees volumes, not revenue
  metric :avg_basket, ratio: %i[revenue count]                        # visible only to roles that see revenue
  metric :customers, count_distinct: :customer_id

  dimension :ordered_at, time: true                                   # default time dimension
  dimension :ship_on                                                  # a second date: "tomorrow" stays ambiguous
  dimension :status

  segment :paid, where: { status: :paid }
  segment :open, where: { status: %i[pending paid] }
end
