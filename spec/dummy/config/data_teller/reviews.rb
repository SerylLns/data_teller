# No account_id on the table: the tenant is reached through the product.
DataTeller.refine Review do
  roles :admin, :support, :member
  tenant_path :product, :account
  synonyms "review", "rating", "avis", "note", "évaluation"

  metric :avg_rating, avg: :rating

  dimension :rating, group: true
  dimension :verified
  dimension :published_on, time: true
end
