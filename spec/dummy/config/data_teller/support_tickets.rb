DataTeller.refine SupportTicket do
  roles :admin, :support
  tenant_path :account
  synonyms "ticket", "support request", "complaint", "demande", "réclamation"

  metric :avg_resolution_minutes, avg: :resolution_minutes
  metric :avg_satisfaction, avg: :satisfaction

  dimension :channel
  dimension :priority
  dimension :status
  dimension :opened_at, time: true
  dimension :resolved_at

  segment :urgent, where: { priority: :urgent }
  segment :unresolved, where: { status: %i[open pending] }
end
