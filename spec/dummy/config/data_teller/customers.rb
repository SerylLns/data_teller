# email and phone are deliberately absent: a column that is not listed here cannot be queried.
DataTeller.refine Customer do
  roles :admin, :support
  tenant_path :account
  synonyms "customer", "client", "buyer", "acheteur"
  # Support sees how customers split, not who they are: a group of fewer than 5 is hidden from it, in any query that reads customers
  # (ADR 0012). An admin can open a customer's page in the app anyway.
  min_group_size 5, except: :admin

  dimension :city
  dimension :name, lookup: :trigram, group: true, max_groups: 20
  dimension :acquisition_channel
  dimension :tier
  dimension :signed_up_on, time: true

  segment :gold, where: { tier: :gold }
end
