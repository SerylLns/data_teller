# email and phone are deliberately absent: a column that is not listed here cannot be queried.
DataTeller.refine Customer do
  roles :admin, :support
  tenant_path :account
  synonyms "customer", "client", "buyer", "acheteur"

  dimension :city
  dimension :name, lookup: :trigram, group: true, max_groups: 20
  dimension :acquisition_channel
  dimension :tier
  dimension :signed_up_on, time: true

  segment :gold, where: { tier: :gold }
end
