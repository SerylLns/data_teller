DataTeller.refine Coupon do
  roles :admin
  tenant_path :account
  synonyms "coupon", "promo code", "discount code", "code promo", "bon de réduction"

  dimension :code, group: true
  dimension :kind
  dimension :starts_on, time: true
  dimension :ends_on
end
