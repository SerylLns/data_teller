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
- **T07b Validation against the models and the schema** — done. The boot never reads the database (ADR 0004 D6). `[sec]`
  - At boot: `c.tenant` model, mandatory `tenant_path` (ADR 0004 D7), metric paths through exposed models only, `scope:` names registered by `scope`,
    sensitive lint extended with `encrypted_attributes` and the host's `filter_parameters`.
  - In `rake data_teller:check`: tables, columns, types (`sum`/`avg` on numbers, `min`/`max` on numbers and dates), `time:` on dates, `lookup:` on text,
    and `scope:` segments, called inside a rolled-back transaction (no argument, no order/limit/group/select).
- **T08 Schema generation from DSL** — done (ADR 0004 D8). Per-role visible catalog with derived metrics, segments and paths; one schema branch per dataset;
  `rake "data_teller:schema[admin]"`; two paths to the same dataset refused at boot. Not a security boundary. Left for T12: caching by permissions fingerprint + registry version,
  and what each provider accepts. The schema does not tie `{lookup}` to `lookup:` dimensions or `granularity` to date dimensions: T22 does.

## M2 — Safe core, no LLM
- **T22 Query validator** — done (`QueryValidator`). Judges the LLM's output against the role's catalog: names, date dimensions rejected in filters, operators and values by type,
  real calendar dates, lookups only where declared, granularity on dates only, `order_by` within the `group_by`, `too_many_groups` on two high-cardinality dimensions. Forbidden and unknown give the same result. `[sec]`
- **T23 Compiler** — done (ADR 0005). Bound parameters, whitelisted operators, LIKE escaped, truncation (`max_groups`, `truncated`), a missing column means a refusal. `QueryRunner` is the entry point. `[sec]`
- **T24 Tenant injection** — done (ADR 0005 D1). A sub-query on every table touched (joins, metric paths), applied last on top of segments, with a structural presence check.
  `scope:` and `default_scope` limited to a whitelist (ADR 0004 D4). `spec/security/`: a matrix of attack vectors against query shapes, on real rows and two tenants, including the two regressions that returned 2001 instead of 1. Still to cover in T31a: soft-delete, STI, nullable tenant. `[sec]`
- **T25 Execution guards** — done (ADR 0005 D3). Read-only transaction, compilation included, statement timeout (`query_timeout`), row, join and group caps as settings, automatic top-N with `truncated`, time-series point cap (`too_many_groups`). `[perf]` `[sec]`
- **T26 Relative dates + tenant time zone** — done (ADR 0005 D2, D4). Periods, date grouping, `compare`. Left, refused until then: relative conditions in segments (`{ days_ago: 30 }`), whose syntax must be decided.
- **T35 Permission basics** — done (ADR 0004 D5). Mandatory dataset roles, narrowing, derived metrics, segments and metrics inherit their columns, paths inherit every dataset on the way, fail-closed resolver,
  one catalog per request (`Catalog.for_user`). Two dimensions on one column with different roles refused at boot. Users and roles (admin / support / member) in the dummy, with fake seeds. `spec/security/permissions_matrix_spec.rb`: every role against every use of a name, and the catalog, the schema and the validator agreeing. `[sec]`
- **T36 Aggregate disclosure.** Declarative `min_group_size`, small-cell suppression; documents the differencing limit. `[sec]`
- **T37 Database read-only role** — done (ADR 0005 D6). `c.database_role`, switched to with `SET LOCAL ROLE`; `rake data_teller:grants` prints the column GRANTs from the declarations; `rake data_teller:check` refuses too few and too many. Columns only, not rows (T39). Recommended, not mandatory. A separate connection may become an option. `[sec]`
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
- **T28 Deterministic explanation** (i18n templates, escaped values, says when a result is truncated). Missing I18n keys become warnings in `Report#warnings`, empty until then. `[sec]`
- **T29 Clarification + refusal** (ADR 0001 D5).
- **T30 Engine endpoint + production UI** (builds on T13b).

## M6 — Hardening & release
- **T31b Full adversarial suite** incl. prompt injection; shipped as shared examples. `[sec]`
- **T32 Per-tenant/user rate limit + token budget.** `[perf]` `[sec]` Decide there whether the execution limits of T25 can vary per tenant or role; they are global today.
- **T33 Pundit adapter** (`unscope(:order)` on aggregates; isolation check in CI, not at boot). `[sec]`
- **T34 Full install generator.** Core piece since ADR 0001 D4. Consider pulling it forward. The minimal generator of T07a only writes the global file;
  this one infers dimensions, labels, tenant path and hidden columns, and writes one file per model plus the locale files.
- **T40 `data_teller-demo` repository** (after M3 and T33). Separate Rails app using the gem like an integrator: Accounts/Users/roles,
  Pundit, several tenants, reusing the dummy's models and fake seeds. Scripted security demo = the Security Test Kit scenarios
  (other-tenant data, forbidden column, injection attempt), with a replay mode of recorded LLM responses so it is deterministic.
  Wording: even if the LLM is fooled, the query stays inside tenant and column limits. Product ranking starts from a LineItem dataset (belongs_to path).
  **Started early, now frozen** (local repo, no remote): a JSON sandbox with the gem's trace, a page comparing what two roles see,
  and nine security scenarios with computed verdicts. Two uses: the public showcase of the gem, and screenshots for the series.
  Until M3 it is presented as "the security layer, before the LLM". Before it goes public:
  - the gem repository is public (the author's call), so the demo's Gemfile and CI stop depending on `../data_teller`;
  - the nine scenarios run as specs in the demo, so the page can never show a green it did not earn;
  - one more scenario: `account_id` declared as a dimension anyway, and filtering on another tenant still returns nothing (the tenant filter is ANDed);
  - hosting hardened: a request rate limit (Rails' `rate_limit`, no new dependency) and the read-only role of T37, since the sandbox runs arbitrary JSON from anyone;
  - decide what of `Catalog` is public API (the roles page reads `Catalog::Entry#fields`), before 0.1.
- **T39 Optional Postgres RLS** (`SET LOCAL` tenant id), defense in depth. `[sec]`
  Unlocks, if real scopes need it at T40: a per-segment escape from the scope whitelist (ADR 0004 D4), like Rust's `unsafe`, so that it is done knowingly.
  Proposed shape, not decided: `segment :vip, scope: :vip_customers, unsafe: "uses LOWER(city), reviewed in #123"`. A reason, not `true`; never a global setting;
  listed by `rake data_teller:check` and warned at boot; refused at boot unless RLS is on, since without it the code is the only line and this would reopen the leaks of the third review.
  First add to the whitelist what is safe by construction (`LOWER`, `LIKE`), and consider sub-queries compiled with their own tenant filter.

## V1
Saved/shared questions as RAG examples · 👍/👎 feedback -> eval dataset · audit log + token cost per tenant ·
answer cache · unanswered-question log with declaration suggestions · PII masking.

## V2
Scheduled reports · threshold alerts · whitelisted actions with human confirmation · embeddable component.
