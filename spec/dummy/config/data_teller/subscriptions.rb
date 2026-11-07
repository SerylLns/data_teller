DataTeller.refine Subscription do
  roles :admin, :support
  tenant_path :account
  synonyms "subscription", "plan", "abonnement", "souscription"

  metric :mrr, sum: :mrr_cents, format: :money, roles: :admin

  dimension :plan
  dimension :status
  dimension :started_on, time: true
  dimension :cancelled_on

  segment :active, where: { status: :active }
  segment :churned, where: { status: :cancelled }
end
