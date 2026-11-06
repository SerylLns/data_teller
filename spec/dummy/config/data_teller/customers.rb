# email and phone are deliberately absent: a column that is not listed here cannot be queried.
DataTeller.refine Customer do
  roles :admin, :support
  synonyms "client", "customer"

  dimension :city
  dimension :name, lookup: :trigram, group: true, max_groups: 20
end
