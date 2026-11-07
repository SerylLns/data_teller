DataTeller.refine Invoice do
  roles :admin
  tenant_path :account
  synonyms "invoice", "billing", "facture", "facturation"

  metric :invoiced, sum: :amount_cents, format: :money

  dimension :status
  dimension :issued_on, time: true
  dimension :due_on
  dimension :paid_at

  segment :unpaid, where: { status: :open }
  segment :paid, where: { status: :paid }
end
