# ADR 0003 — Positioning, security additions and development order

Status: accepted

## Positioning

Tagline: **Secure natural-language data access for Rails applications.**
Message: the LLM never touches the database and never writes a query. Say that, not "without exposing the
database to an LLM" (text-to-SQL tools do not give the LLM a direct connection either).

Differentiators, combined: (1) end-user oriented, meant for a SaaS's own customers; (2) no text-to-SQL, the model
produces a structured intent and the engine controls its translation to ActiveRecord; (3) security integrated with the
app (reuses the host's authorization, while enforcing its own isolation and exposure rules); (4) a declarative semantic
layer that is ActiveRecord-native (business concepts, not free schema exploration). A semantic layer alone is not new
(Cube, dbt); the Rails-native, authorization-aware, end-user angle is what we claim.

Claims rule: no absolute wording ("impossible to bypass"). Every guarantee is stated as something the Security Test Kit verifies.
A competitive check was done on 2026-11-06 (see below). Re-verify the closest projects directly on GitHub/rubygems before part 0 is published.

## Security additions (new tickets T35-T39)

- **Aggregate disclosure.** Counts and aggregates can leak (e.g. "how many earn > X" narrowed to one person).
  Declarative `min_group_size` suppresses small cells. It does not stop differencing attacks (two queries, one row apart),
  so rate limits and audit remain necessary. State this limit openly.
- **Database-level read-only.** A dedicated SELECT-only role with column-level GRANTs on exposed columns only, so even a
  compiler bug cannot read an unexposed column. Recommended, not mandatory (a second connection is an adoption cost);
  a read-only transaction alone is not considered sufficient.
- **Query complexity budget.** Beyond row limits and statement timeout: planner cost check with `EXPLAIN (FORMAT JSON)`
  before execution, reject above a configurable threshold.
- **Optional Postgres RLS** as defense in depth (`SET LOCAL` of the tenant id per transaction). Optional, V1.
- **Security Test Kit** becomes a flagship feature: explicit, reproducible adversarial tests, shipped as shared examples
  integrators run against their own declarations and policies. Split: v0 on JSON fixtures without any LLM (M2),
  full adversarial suite including prompt injection after the LLM exists (M6).
- Permissions engine basics (roles on dataset/metric/dimension) move from V1 into the MVP. Tenant isolation stays in
  the compiler first; Pundit is an additional layer, never the only one.

## Development order (option "C")

Everything that is safe and testable without an LLM comes first, using the hand-written IR fixtures:
DSL -> validator, compiler, tenant injection, execution guards, permission basics, Security Test Kit v0 ->
eval + LLM baseline -> RAG -> trust UX -> hardening. The LLM lands around series part 8 instead of part 13.

Why: coherent with a security positioning, avoids building LLM flows on an unsafe base, and the core is cheap to test
without a model. Rejected: strict security-first order with the LLM sixth of eight (months without any AI content,
which contradicts the project's learning goal), and keeping the previous order (compiler after the LLM and RAG).

## Competitive check (2026-11-06)

Source: web research by a subagent; much of it comes from marketing pages and listicles. Treat as a starting point, not proof.

Rails/Ruby ecosystem (all small and young, admin-oriented):
- `blazer-ai`, `query_lens`, `rails-nl2sql`: text-to-SQL for admins. `query_lens` and `Glancer` already have read-only transactions,
  timeouts and audit logs (these are table stakes, not differentiators).
- `Glancer`: RAG chat engine; default mode generates SQL, `:activerecord` mode generates Ruby filtered by a denylist.
  No tenant handling or host authorization found.
- `ai_record_finder`: **closest Rails project**. LLM emits a JSON DSL validated and compiled to ActiveRecord with an association
  whitelist; claims "tenant-safe" without documenting how. AGPL-3.0, very few downloads. No semantic layer, Pundit or test kit found.
  Verify its maintenance status directly (conflicting signals).
- Outside Rails: Cube (semantic layer with an AI API and multi-tenancy; same philosophy, but an external service over a warehouse),
  Metabase (AI in the open-source edition), Vanna (archived), WrenAI, and embedded-analytics products (Luzmo, Holistics, Explo, ThoughtSpot).
  Not verified in depth.

What holds up: end-user orientation within the Rails ecosystem; reuse of the host app's authorization (Pundit), found nowhere else;
an ActiveRecord-native declarative semantic layer. What does not hold as a unique claim: "no text-to-SQL" (Cube, ai_record_finder),
"tenant-safe NL queries", "no data sent to the LLM".

Claims to avoid: "first NL query for Rails", "first to avoid text-to-SQL", presenting read-only/audit/timeouts as differentiators.
Claim the mechanism instead (compiler-injected tenant scope, host authorization reuse, declared semantic layer) and the evidence
(Security Test Kit). Honest framing vs Cube: it lives inside the Rails app, queries its own models and reuses its authorization.
