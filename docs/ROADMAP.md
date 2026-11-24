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
  `scope:` and `default_scope` limited to a whitelist (ADR 0004 D4). `spec/security/`: a matrix of attack vectors against query shapes, on real rows and two tenants, including the two regressions that returned 2001 instead of 1. Soft-delete, STI and nullable keys: covered in T31a. `[sec]`
- **T25 Execution guards** — done (ADR 0005 D3). Read-only transaction, compilation included, statement timeout (`query_timeout`), row, join and group caps as settings, automatic top-N with `truncated`, time-series point cap (`too_many_groups`). `[perf]` `[sec]`
- **T26 Relative dates + tenant time zone** — done (ADR 0005 D2, D4). Periods, date grouping, `compare`. Left, refused until then: relative conditions in segments (`{ days_ago: 30 }`), whose syntax must be decided.
- **T35 Permission basics** — done (ADR 0004 D5). Mandatory dataset roles, narrowing, derived metrics, segments and metrics inherit their columns, paths inherit every dataset on the way, fail-closed resolver,
  one catalog per request (`Catalog.for_user`). Two dimensions on one column with different roles refused at boot. Users and roles (admin / support / member) in the dummy, with fake seeds. `spec/security/permissions_matrix_spec.rb`: every role against every use of a name, and the catalog, the schema and the validator agreeing. `[sec]`
- **T36 Aggregate disclosure** — done (ADR 0012). `min_group_size N, of:, except:` per dataset, no global default; every protected dataset a query reads counted by its own unit
  in a SQL `HAVING`, `COUNT(*)` where it is exact. Small groups left out and counted (`suppressed`, shown in the palette); a single value under N refused with
  `group_too_small`, zero included; `compare` checks both periods. The dummy protects customers from support. Documented, not solved: totals, `min`/`max`,
  dominance, differencing. Left: one pass instead of two queries if a real integration hits the timeout (measured in D3); a unit two steps away. `[sec]` `[perf]`
- **T37 Database read-only role** — done (ADR 0005 D6). `c.database_role`, switched to with `SET LOCAL ROLE`; `rake data_teller:grants` prints the column GRANTs from the declarations; `rake data_teller:check` refuses too few and too many. Columns only, not rows (T39). Recommended, not mandatory. A separate connection may become an option. `[sec]`
- **T39 Optional Postgres RLS** — done (ADR 0005 D7). `c.row_security`, the tenant set with `set_config`, policies chained along the tenant_path and printed by `rake data_teller:grants`, tried for real by `rake data_teller:check`. `[sec]` Moved up from M6 (2026-11-07): the seven tenant leaks of the third review all came from code
  judging SQL; the LLM adds a new source of unexpected queries, so the database should hold the tenant line before it is plugged in. Builds on the role of T37.
  Still open, now possible if real scopes need it at T40: a per-segment escape from the scope whitelist (ADR 0004 D4), like Rust's `unsafe`, so that it is done knowingly.
  Proposed shape, not decided: `segment :vip, scope: :vip_customers, unsafe: "uses LOWER(city), reviewed in #123"`. A reason, not `true`; never a global setting;
  listed by `rake data_teller:check` and warned at boot; refused at boot unless RLS is on, since without it the code is the only line and this would reopen the leaks of the third review.
  First add to the whitelist what is safe by construction (`LOWER`, `LIKE`), and consider sub-queries compiled with their own tenant filter.
- **T38 Query budget** — done (ADR 0013). `query_timeout` is a budget for the whole question: the time left is set before each statement, so a
  protected `compare` no longer holds a connection for four timeouts. `max_query_cost`, off by default: every statement planned with `EXPLAIN` before any
  runs, the sum compared, `too_complex` over it. `rake data_teller:costs` prints the kit's queries' estimated costs next to their real durations, to choose
  the threshold. Left: the costs of real, combined questions, at T40. `[perf]`
- **T31a Security Test Kit v0** (ADR 0011). `[sec]`
  - Done: specs for single table inheritance, soft-delete and nullable keys (`spec/security/table_shapes_spec.rb`), on three tables of the dummy that the catalog does not expose.
  - Done: a compiled plan gives the kit the datasets it filtered, the primary keys of every row it reads and the tables its SQL reads (ADR 0011 D5).
  - Done: `DataTeller::IsolationCheck` and `rake data_teller:isolation`: on the integrator's own tables, every row read by one query per declaration is checked against
    its owner, found through the Ruby associations. Every declared role at once; three tenants by default, `TENANTS=` to choose. Ids only in the report.
  - Later: RSpec shared examples and a Minitest assertion over the same core; fuzzing (`FUZZ=`); sensitive aggregates and inference via filters/order/derived
    metrics, which are T36's subject.

## M3 — Evaluation & LLM baseline
- **T09 Eval dataset v0** (ADR 0006) — working set done (37 questions in `spec/dummy/eval/dev.yml`, checked by `spec/dummy_app/eval_dataset_spec.rb`); held-out set: 10 questions by the author, seen during development, kept out of tuning (ADR 0006 D3). 40 questions -> expected IR, in English and French (traps: synonyms, ambiguity, out-of-scope, relative dates, cross-tenant). 30 dev / 10 held-out, the held-out ones written by the author.
  First, the dummy app grows to an e-commerce domain of eleven or twelve datasets, built for confusable names (ADR 0006 D1).
- **T10 Scorer** — done (ADR 0006 D4). Right or wrong per question after normalization, fields that differ, error class and severity, same rows flagged for review.
- **T11 `rake data_teller:eval`** — done. A model is anything answering a request (id, language, text, role, day) with an output, tokens and latency; `perfect` calibrates the harness at 100%, `replay` scores a saved run again. `SAVE=1` writes `eval/runs/*.json`; a held-out run keeps ids and numbers only.
- **T12 Provider client** — done (ADR 0008). An adapter is `complete(system:, user:, schema:)` plus `provider_schema(schema)`; the gem keeps the prompts and the chain.
  Raw HTTP, structured outputs, timeouts, retries, token + latency logging. `[dep]` HTTP client only if needed. `[sec]`
- **T13 Naive baseline** — done (ADR 0007 D1, ADR 0009): the role's whole catalog in the prompt, `MODEL=naive`, run once for the reference number: 79.7% on the working set with `gpt-6-luna`; no iteration on it, never shipped.
- **T13c Router** — done (ADR 0007 D1, D3-D5): a first call picks one to three datasets from the role's index, the second gets the schema narrowed to them. `MODEL=routed`, scored separately. Measured on 11 datasets: the whole catalog does a little better, so the router only runs above `c.route_above_datasets` (D6, an estimate: no large catalog run yet). `[sec]` `[perf]`
- **T13b Minimal command palette** — done (ADR 0002, ADR 0010). `DataTeller.ask`, `POST /ask` answering HTML fragments, the `data_teller_palette` helper, a web component on `<dialog>` with no dependency; 503 and no palette when the engine is off (ADR 0004 D6). The question is filtered out of Rails' logs. In the dummy, a fake sign-in in development and test only.
  Left for T28 and T30: money shown in raw cents, column labels, clickable clarification options, the JS loaded on first open (ADR 0002), a browser test. No per-user limit until T32: not for production before that. Herb not added.
- **T14 Prompt iteration log**, on the whole-catalog path (ADR 0007 D6). One change = several eval runs = one commit: one run moves by 1 to 3 answers on its own (ADR 0007).

## M4 — Retrieval (RAG)
- **T15 Indexable documents.** **T16 Embeddings pipeline** `[dep]` `[perf]` `[sec]` (only declared labels leave the app).
- **T17 Retrieval A (vectors).** **T18 Retrieval B (hybrid, trigram + vectors, RRF)** (ADR 0007 D2). Recall@k over datasets, scored separately,
  against the T13c router: retrieval has to beat one cheap LLM call, not "send everything". `tsvector` as an extra variant, to decide at T18.
- **T19 Retrieval-scoped prompt** vs the T13 baseline and the T13c router. **T20 Dynamic few-shot** (filtered by tenant and by the role's visible catalog). **T21 (optional) reranking.**
- **T27 Value resolution.** Local lookup resolvers per dimension (ADR 0001 D2). The isolation kit (T31a) then probes each `lookup:` dimension with another
  tenant's value through the lookup: today it reports them as not tried (`lookup_required`). `[sec]`

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
- **Found in the first real integration, not decided yet** (2026-11-23/24, a production app tried locally on fake data, the palette used
  by its author). Each one a decision of its own, labels first:
  - **Labels.** The palette shows raw identifiers to the end user: dataset and metric names over the result, column headers (`count`, a
    dimension name), ISO dates, in an interface in another language. No label is declared for a dataset, a metric or a dimension.
  - **A word shared by two datasets.** The app's own screens used one word for two datasets. On one dataset as a synonym, the model never
    asks; on neither, it falls on the dataset whose name translates it. No way to declare a word ambiguous so that the model asks.
  - **Amounts in cents as a dimension.** Filtering on a price needs the cents column as a dimension, and the model converts "500 euros"
    itself. `format: :money` exists for metrics only.
  - **A refusal that says what is missing.** "Not in this form" for a filter on an undeclared column gives the user nothing to rephrase with.
  - **A catalog that depends on the tenant.** Tenants of different kinds (a mode, a plan) use the same word for different datasets, and some
    have no rows in a dataset at all, which the model is still offered. A dataset's roles are any-of, so roles cannot say it.
  - **Questions asking for a list** ("show me the ...") are the first a user types, and get the generic refusal. Lists are out of scope by
    design (ADR 0004 D2); the refusal could say the gem answers with numbers and offer the count.
  - **A path through an optional `belongs_to`** drops the rows with no parent (inner join): a total and a breakdown by that parent disagree
    silently. More common than the soft-delete case the README notes.
  - **A user who sees several tenants.** The tenant resolver returns one; such users get the narrower view.
  - **The catalog lists enum values an `always` condition hides**; filtering on one returns 0.
  - **The quick start does not show `c.current_user`**: without it the palette renders nothing and the endpoint answers 401, with no message (T41).
  - **Eval noise.** On a 28-question set, 3 or 4 answers of 56 moved between two runs with nothing changed for them: one run does not compare
    two declarations.
- **T43 The eval's "to review" flag in a host app** (done 2026-11-24, [ADR 0015](adr/0015-eval-executor-without-user.md)). Found in the first
  real integration: the executor built a user only the dummy's resolvers could read, so `same_result` was always false elsewhere. It now runs
  a query from the question's role and the set's tenant, as the isolation kit does.
- **T42 Conditions always applied** (done 2026-11-23, [ADR 0014](adr/0014-always-conditions.md)). Found in the first real integration: rows
  an app hides without a `default_scope` (a status left out by its policy scope, `discard`) were counted. `always where:` / `always scope:` on a
  dataset, applied on every table the query reads, joins included. Not a security item: it only narrows, the tenant filter does not depend on it.
- **T41 Integrator documentation.** Added 2026-11-23: the README is both the pitch and the only guide, and no reference exists, so some DSL
  options (`synonyms`, `max_groups`, `lookup:`, `group:`) are documented nowhere. Markdown in `docs/`, no site and no new dependency until the gem
  is published. In order:
  - **References**, the stable part: every DSL keyword with its options, every setting with its default, every rake task. A spec fails when a
    setting or a keyword is missing from them, so the reference cannot drift in silence.
  - **An integration guide**, written during the first real integration (the production app tried locally, then T40): its gaps show where an
    integrator falls into them, not where they are guessed.
  - **The README back to a showcase**: the pitch, a quick start, links to the guide, the references and the security model.
  - A site (and a choice of tool) at publication, with T34.
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

Follow-up questions: each question is alone today, so "and in June?" after "revenue last month" comes back as a clarification (seen by the author in the palette, 2026-11-08). To think through, nothing decided: what context to carry, and how (the previous validated query rather than the chat text would keep rows and model text out of the prompt), and how the eval scores a conversation.

## V2
Scheduled reports · threshold alerts · whitelisted actions with human confirmation · embeddable component.
