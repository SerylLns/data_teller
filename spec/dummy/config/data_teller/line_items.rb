# No account_id on the table: the tenant is two steps away, through the order.
DataTeller.refine LineItem do
  roles :admin, :member
  tenant_path :order, :account
  synonyms "order line", "units sold", "ligne de commande", "unités vendues"

  metric :units, sum: :quantity
  metric :avg_unit_price, avg: :unit_price_cents, format: :money, roles: :admin
end
