DataTeller.refine Order do
  roles :admin, :support
  synonyms "commande", "order"

  metric :revenue, sum: :total_cents, format: :money, roles: :admin   # support sees volumes, not revenue
  metric :avg_basket, ratio: %i[revenue count]                        # visible only to roles that see revenue
  metric :customers, count_distinct: :customer_id

  dimension :ordered_at, time: true                                   # default time dimension
  dimension :ship_on                                                  # a second date: "tomorrow" stays ambiguous
  dimension :status
  dimension :customer_city, column: "customer.city"
  dimension :customer_name, column: "customer.name", lookup: :trigram, group: true, max_groups: 20

  segment :paid, where: { status: :paid }
  segment :open, where: { status: %i[pending paid] }
end
