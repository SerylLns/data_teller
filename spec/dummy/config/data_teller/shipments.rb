DataTeller.refine Shipment do
  roles :admin, :support
  tenant_path :order, :account
  synonyms "shipment", "delivery", "shipping", "expédition", "livraison", "envoi"

  metric :shipping_cost, sum: :cost_cents, format: :money, roles: :admin

  dimension :carrier
  dimension :shipped_at, time: true
  dimension :delivered_on
end
