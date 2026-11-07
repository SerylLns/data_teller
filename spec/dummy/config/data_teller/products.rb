DataTeller.refine Product do
  roles :admin, :support, :member
  tenant_path :account
  synonyms "product", "item", "article", "produit"

  metric :avg_price, avg: :price_cents, format: :money

  dimension :name, lookup: :trigram, group: true, max_groups: 20
  dimension :category
  dimension :active
  dimension :launched_on, time: true

  segment :active, where: { active: true }
end
