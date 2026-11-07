DataTeller.refine Refund do
  roles :admin, :support
  tenant_path :order, :account
  synonyms "refund", "return", "remboursement", "retour"

  metric :refunded_amount, sum: :amount_cents, format: :money, roles: :admin

  dimension :reason
  dimension :refunded_at, time: true
end
