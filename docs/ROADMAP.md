# DataTeller — Implementation plan & tickets

Goal: ship a safe NL-to-structured-query Rails engine **and** learn LLM integration + RAG at a low level.
Principles: eval before prompts, measure retrieval and generation separately, no orchestration framework,
the LLM never writes SQL. Order decided in ADR 0003 (option C: safe core first, without an LLM).

Legend: `[dep]` new dependency, `[sec]` security-relevant, `[perf]` performance-relevant.

## M0 — Foundations (done: T01-T03)
- **T01 Gem skeleton** (RSpec, RuboCop, CI). **T02 Dummy app domain + fake seeds.** **T03 Postgres + pgvector.**
- **T04 Decision log** (`docs/adr/`).

## M1 — DSL & query format
- **T05 Query format** (JSON Schema, fixtures) — done, ADR 0001.
- **T06 Declaration DSL.** `configure`, `expose`, `refine` (segments, metrics, dimensions, synonyms, labels), registry object.
- **T07 Mandatory tenant.** Boot fails without `c.tenant`. `[sec]`
- **T08 Schema generation from DSL.** Enums of declared names only.

## M2 — Safe core, no LLM
- **T22 IR validator.** Declared names, date dimensions rejected in filters, depth, operators/types. `[sec]`
- **T23 Compiler IR -> ActiveRecord.** Bound parameters only, whitelisted operators, escape LIKE wildcards. `[sec]`
- **T24 Tenant path + injection** on every table touched (joins, lookups). Specs: default_scope, soft-delete, STI, nullable tenant. `[sec]`
- **T25 Execution guards.** Read-only transaction, statement timeout, row limit, join cap; cardinality rule of ADR 0004 D3
  (`max_groups` per dimension, `LIMIT n+1` check, top-N required for high-cardinality group_by, time-series point cap). `[perf]` `[sec]`
- **T26 Relative dates + tenant time zone** resolved in the compiler.
- **T35 Permission basics.** Roles on dataset / metric / dimension; path permissions inherited from target. `[sec]`
  Adds Users and roles (admin / support / member) to the dummy app, with fake seeds.
- **T36 Aggregate disclosure.** Declarative `min_group_size`, small-cell suppression; documents the differencing limit. `[sec]`
- **T37 Database read-only role.** SELECT-only role with column-level GRANTs on exposed columns; boot check; recommended, not mandatory. `[sec]`
- **T38 Query complexity budget.** `EXPLAIN (FORMAT JSON)` cost check before execution. `[perf]`
- **T31a Security Test Kit v0.** Cross-tenant ids, forbidden columns and associations, sensitive aggregates, run on JSON fixtures; shared examples. `[sec]`

## M3 — Evaluation & LLM baseline
- **T09 Eval dataset v0.** 40 French questions -> expected IR (traps: synonyms, ambiguity, out-of-scope, relative dates, cross-tenant). 30 dev / 10 held-out.
- **T10 Scorer** (per-field; decision, reason, options; unnecessary clarifications). **T11 `rake data_teller:eval`.**
- **T12 Provider client.** Raw HTTP, structured outputs, timeouts, retries, token + latency logging. `[dep]` HTTP client only if needed. `[sec]`
- **T13 Naive pipeline** (whole registry in the prompt); baseline recorded in an ADR.
- **T13b Minimal command palette** (ADR 0002): web component + `<dialog>`, dev-only mount in the dummy app, for series visuals.
  Herb only as an optional dev tool, flagged when added.
- **T14 Prompt iteration log.** One change = one eval run = one commit.

## M4 — Retrieval (RAG)
- **T15 Indexable documents.** **T16 Embeddings pipeline** `[dep]` `[perf]` `[sec]` (only declared labels leave the app).
- **T17 Retrieval A (vectors).** **T18 Retrieval B (hybrid, tsvector + vectors, RRF).** Recall@k scored separately.
- **T19 Retrieval-scoped prompt** vs the T13 baseline. **T20 Dynamic few-shot.** **T21 (optional) reranking.**
- **T27 Value resolution.** Local lookup resolvers per dimension (ADR 0001 D2). `[sec]`

## M5 — Trust UX
- **T28 Deterministic explanation** (i18n templates, escaped values). `[sec]`
- **T29 Clarification + refusal** (ADR 0001 D5).
- **T30 Engine endpoint + production UI** (builds on T13b).

## M6 — Hardening & release
- **T31b Full adversarial suite** incl. prompt injection; shipped as shared examples. `[sec]`
- **T32 Per-tenant/user rate limit + token budget.** `[perf]` `[sec]`
- **T33 Pundit adapter** (`unscope(:order)` on aggregates; isolation check in CI, not at boot). `[sec]`
- **T34 Install generator.** Core piece since ADR 0001 D4. Consider pulling it forward.
- **T40 `data_teller-demo` repository** (after M3 and T33). Separate Rails app using the gem like an integrator: Accounts/Users/roles,
  Pundit, several tenants, reusing the dummy's models and fake seeds. Scripted security demo = the Security Test Kit scenarios
  (other-tenant data, forbidden column, injection attempt), with a replay mode of recorded LLM responses so it is deterministic.
  Wording: even if the LLM is fooled, the query stays inside tenant and column limits. Product ranking starts from a LineItem dataset (belongs_to path).
- **T39 Optional Postgres RLS** (`SET LOCAL` tenant id), defense in depth. `[sec]`

## V1
Saved/shared questions as RAG examples · 👍/👎 feedback -> eval dataset · audit log + token cost per tenant ·
answer cache · unanswered-question log with declaration suggestions · PII masking.

## V2
Scheduled reports · threshold alerts · whitelisted actions with human confirmation · embeddable component.
