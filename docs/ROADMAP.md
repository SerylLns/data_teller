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
- **T06 Declaration DSL** — done. `configure`, `expose`, `refine` (segments, metrics, dimensions, synonyms), registry object, loading of `config/data_teller*.rb`.
- **T07a Boot validation without the database** — done (ADR 0004 D6). Mandatory tenant, collected errors, frozen versioned registry, `on_invalid_config`,
  `rake data_teller:check`, minimal `rails generate data_teller:install`. `[sec]`
- **T07b Boot validation against the ActiveRecord schema.** Must be done before T23/T24: T07a only proves `c.tenant` is set, not that the tenant can be reached. `[sec]`
  - Tenant path found for every exposed model; ambiguous = error (ADR 0004 D6).
  - Columns and associations exist: dimensions, metric columns and paths, `where:` keys, `scope:` names.
  - `scope:` lint (ADR 0004 D4) reads the arity only and **never calls the method at boot**: the name could be anything the model answers to.
  - `min` / `max` limited to numeric and date columns: on a string column they return a stored value, i.e. row-level disclosure.
  - Sensitive lint also reads `encrypted_attributes` and the host's `filter_parameters`, because a word list cannot be complete.
  - Dotted paths derived from exposed models (ADR 0001 D4); two paths to the same dimension = error.
  - Missing I18n keys are warnings; `Report#warnings` exists for them and is empty until then.
- **T08 Schema generation from DSL.** Enums of declared names only, per role (visible catalog); not a security boundary.

## M2 — Safe core, no LLM
- **T22 IR validator.** Declared names, date dimensions rejected in filters, depth, operators/types. Real calendar dates (the schema still accepts `2024-02-31`) and `from` <= `to` in `between`. `[sec]`
- **T23 Compiler IR -> ActiveRecord.** Bound parameters only, whitelisted operators, escape LIKE wildcards. `[sec]`
- **T24 Tenant path + injection** on every table touched (joins, lookups), applied last on top of segments with a structural presence check. Specs: default_scope, soft-delete, STI, nullable tenant. `[sec]`
- **T25 Execution guards.** Read-only transaction, statement timeout, row limit, join cap; cardinality rule of ADR 0004 D3
  (`max_groups` per dimension, `LIMIT n+1` check, top-N required for high-cardinality group_by, time-series point cap). `[perf]` `[sec]`
- **T26 Relative dates + tenant time zone** resolved in the compiler.
- **T35 Permission basics** (ADR 0004 D5). Dataset roles mandatory, narrowing inheritance, derived-metric intersection, segment
  inheritance, fail-closed role resolver, single per-request visible-catalog object. `[sec]`
  Adds Users and roles (admin / support / member) to the dummy app, with fake seeds.
- **T36 Aggregate disclosure.** Declarative `min_group_size`, small-cell suppression; documents the differencing limit. `[sec]`
- **T37 Database read-only role.** SELECT-only role with column-level GRANTs on exposed columns; boot check; recommended, not mandatory. `[sec]`
- **T38 Query complexity budget.** `EXPLAIN (FORMAT JSON)` cost check before execution. `[perf]`
- **T31a Security Test Kit v0.** Cross-tenant ids, forbidden columns and associations, sensitive aggregates, hostile scopes, inference via
  filters/order/derived metrics, catalog consistency across the chain; run on JSON fixtures; shared examples. `[sec]`

## M3 — Evaluation & LLM baseline
- **T09 Eval dataset v0.** 40 French questions -> expected IR (traps: synonyms, ambiguity, out-of-scope, relative dates, cross-tenant). 30 dev / 10 held-out.
- **T10 Scorer** (per-field; decision, reason, options; unnecessary clarifications). **T11 `rake data_teller:eval`.**
- **T12 Provider client.** Raw HTTP, structured outputs, timeouts, retries, token + latency logging. `[dep]` HTTP client only if needed. `[sec]`
- **T13 Naive pipeline** (whole registry in the prompt); baseline recorded in an ADR.
- **T13b Minimal command palette** (ADR 0002): web component + `<dialog>`, dev-only mount in the dummy app, for series visuals.
  First endpoint, so it also wires `DataTeller.enabled?`: routes answer 503 and the palette is not rendered when the engine is off (ADR 0004 D6).
  Herb only as an optional dev tool, flagged when added.
- **T14 Prompt iteration log.** One change = one eval run = one commit.

## M4 — Retrieval (RAG)
- **T15 Indexable documents.** **T16 Embeddings pipeline** `[dep]` `[perf]` `[sec]` (only declared labels leave the app).
- **T17 Retrieval A (vectors).** **T18 Retrieval B (hybrid, tsvector + vectors, RRF).** Recall@k scored separately.
- **T19 Retrieval-scoped prompt** vs the T13 baseline. **T20 Dynamic few-shot** (filtered by tenant and by the role's visible catalog). **T21 (optional) reranking.**
- **T27 Value resolution.** Local lookup resolvers per dimension (ADR 0001 D2). `[sec]`

## M5 — Trust UX
- **T28 Deterministic explanation** (i18n templates, escaped values). `[sec]`
- **T29 Clarification + refusal** (ADR 0001 D5).
- **T30 Engine endpoint + production UI** (builds on T13b).

## M6 — Hardening & release
- **T31b Full adversarial suite** incl. prompt injection; shipped as shared examples. `[sec]`
- **T32 Per-tenant/user rate limit + token budget.** `[perf]` `[sec]`
- **T33 Pundit adapter** (`unscope(:order)` on aggregates; isolation check in CI, not at boot). `[sec]`
- **T34 Full install generator.** Core piece since ADR 0001 D4. Consider pulling it forward. The minimal generator of T07a only writes the global file;
  this one infers dimensions, labels, tenant path and hidden columns, and writes one file per model plus the locale files.
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
