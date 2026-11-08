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
- **T39 Optional Postgres RLS** — done (ADR 0005 D7). `c.row_security`, the tenant set with `set_config`, policies chained along the tenant_path and printed by `rake data_teller:grants`, tried for real by `rake data_teller:check`. `[sec]` Moved up from M6 (2026-11-07): the seven tenant leaks of the third review all came from code
  judging SQL; the LLM adds a new source of unexpected queries, so the database should hold the tenant line before it is plugged in. Builds on the role of T37.
  Still open, now possible if real scopes need it at T40: a per-segment escape from the scope whitelist (ADR 0004 D4), like Rust's `unsafe`, so that it is done knowingly.
  Proposed shape, not decided: `segment :vip, scope: :vip_customers, unsafe: "uses LOWER(city), reviewed in #123"`. A reason, not `true`; never a global setting;
  listed by `rake data_teller:check` and warned at boot; refused at boot unless RLS is on, since without it the code is the only line and this would reopen the leaks of the third review.
  First add to the whitelist what is safe by construction (`LOWER`, `LIKE`), and consider sub-queries compiled with their own tenant filter.
- **T38 Query complexity budget.** `EXPLAIN (FORMAT JSON)` cost check before execution. `[perf]`
- **T31a Security Test Kit v0.** Cross-tenant ids, forbidden columns and associations, sensitive aggregates, hostile scopes, inference via
  filters/order/derived metrics, catalog consistency across the chain; run on JSON fixtures; shared examples. `[sec]`

## M3 — Evaluation & LLM baseline
- **T09 Eval dataset v0** (ADR 0006) — working set done (37 questions in `spec/dummy/eval/dev.yml`, checked by `spec/dummy_app/eval_dataset_spec.rb`); held-out set: the author's, kept out of development. 40 questions -> expected IR, in English and French (traps: synonyms, ambiguity, out-of-scope, relative dates, cross-tenant). 30 dev / 10 held-out, the held-out ones written by the author.
  First, the dummy app grows to an e-commerce domain of eleven or twelve datasets, built for confusable names (ADR 0006 D1).
- **T10 Scorer** — done (ADR 0006 D4). Right or wrong per question after normalization, fields that differ, error class and severity, same rows flagged for review.
- **T11 `rake data_teller:eval`** — done. A model is anything answering a request (id, language, text, role, day) with an output, tokens and latency; `perfect` calibrates the harness at 100%, `replay` scores a saved run again. `SAVE=1` writes `eval/runs/*.json`; a held-out run keeps ids and numbers only.
- **T12 Provider client** — done (ADR 0008). An adapter is `complete(system:, user:, schema:)` plus `provider_schema(schema)`; the gem keeps the prompts and the chain.
  Raw HTTP, structured outputs, timeouts, retries, token + latency logging. `[dep]` HTTP client only if needed. `[sec]`
- **T13 Naive baseline** — done (ADR 0007 D1, ADR 0009): the role's whole catalog in the prompt, `MODEL=naive`, run once for the reference number: 79.7% on the working set with `gpt-6-luna`; no iteration on it, never shipped.
- **T13c Router** (ADR 0007 D1): a first call picks the datasets from the role's dataset index, the second gets the schema narrowed to them.
  Scored separately (expected dataset in the choice). To decide there: how many datasets, `out_of_scope` from the router, one model or two. `[sec]` `[perf]`
- **T13b Minimal command palette** (ADR 0002): web component + `<dialog>`, dev-only mount in the dummy app, for series visuals.
  First endpoint, so it also wires `DataTeller.enabled?`: routes answer 503 and the palette is not rendered when the engine is off (ADR 0004 D6).
  Herb only as an optional dev tool, flagged when added.
- **T14 Prompt iteration log**, on the routed path (ADR 0007 D1). One change = one eval run = one commit.

## M4 — Retrieval (RAG)
- **T15 Indexable documents.** **T16 Embeddings pipeline** `[dep]` `[perf]` `[sec]` (only declared labels leave the app).
- **T17 Retrieval A (vectors).** **T18 Retrieval B (hybrid, trigram + vectors, RRF)** (ADR 0007 D2). Recall@k over datasets, scored separately,
  against the T13c router: retrieval has to beat one cheap LLM call, not "send everything". `tsvector` as an extra variant, to decide at T18.
- **T19 Retrieval-scoped prompt** vs the T13 baseline and the T13c router. **T20 Dynamic few-shot** (filtered by tenant and by the role's visible catalog). **T21 (optional) reranking.**
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
- **T40 `data_teller-demo` repository** (after T13b). Separate Rails app using the gem like an integrator. Decided 2026-11-07, two parts in one app:
  - **The demo: a fake merchant back-office** (dashboard, orders, a customer page; 3 or 4 read-only pages, generated from fake seeds, no real
    back-office features) with the DataTeller palette of T13b as the point of it: an end user asks, and gets the answer the way a real app would show it.
    Same domain as the dummy app's evaluation domain (ADR 0006 D1), so that the eval, the demo and the articles talk about the same data.
    Scripted security demo with a replay mode of recorded LLM responses so it is deterministic. Wording: even if the LLM is fooled,
    the query stays inside tenant and column limits.
  - **"Under the hood", for developers: the pages already built** while the demo was frozen (local repo, no remote): the JSON sandbox with
    the gem's trace, the page comparing what two roles see, and nine security scenarios with computed verdicts. Also the series' screenshots.
  Built once the LLM answers (T13, T13b): a back-office with no working palette is an empty set. Before it goes public:
  - the gem repository is public (the author's call), so the demo's Gemfile and CI stop depending on `../data_teller`;
  - the nine scenarios run as specs in the demo, so the page can never show a green it did not earn;
  - one more scenario: `account_id` declared as a dimension anyway, and filtering on another tenant still returns nothing (the tenant filter is ANDed);
  - hosting hardened: a request rate limit (Rails' `rate_limit`, no new dependency), the read-only role of T37 and the row security of T39,
    since the sandbox runs arbitrary JSON from anyone, and an LLM budget per visitor once the palette calls a provider;
  - decide what of `Catalog` is public API (the roles page reads `Catalog::Entry#fields`), before 0.1.

## V1
Saved/shared questions as RAG examples · 👍/👎 feedback -> eval dataset · audit log + token cost per tenant ·
answer cache · unanswered-question log with declaration suggestions · PII masking.

## V2
Scheduled reports · threshold alerts · whitelisted actions with human confirmation · embeddable component.
