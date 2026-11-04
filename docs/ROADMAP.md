# DataTeller — Implementation plan & tickets

Goal: ship a safe NL-to-structured-query Rails engine **and** learn LLM integration + RAG at a low level.
Principles: eval before features, measure retrieval and generation separately, no orchestration framework,
the LLM never writes SQL.

Decision (IR expressiveness): **option B** — single metric, filters, group_by, order_by, limit,
period comparison, top-N. Ratios are derived metrics declared in the DSL, not composed by the LLM.

Legend: `[dep]` = new dependency to flag, `[sec]` = security-relevant, `[perf]` = performance-relevant.

---

## M0 — Foundations

- **T01 Gem skeleton.** `rails plugin new data_teller --mountable --dummy-path=spec/dummy`, RSpec, Standard/Rubocop, CI.
  *Done when:* `bundle exec rspec` passes on an empty suite in CI.
- **T02 Dummy app domain + seeds.** Models: Account (tenant), Customer, Order, Shipment, Product, LineItem.
  Seeds on **fake data** (flagged as such), 3 accounts, enough rows for meaningful aggregates.
  *Done when:* `rails db:seed` yields ≥ 2 accounts with distinct data.
- **T03 Postgres + pgvector in dev.** Docker compose. `[dep]` pgvector extension, `neighbor` gem (later, T20).
- **T04 Decision log.** `docs/adr/` — one short file per architectural decision (IR, retrieval, provider).

## M1 — DSL & query IR

- **T05 Query IR spec.** JSON schema for the structured query (option B), versioned, with examples.
  *Done when:* schema + 15 valid and 15 invalid fixtures validated by a spec.
- **T06 Declaration DSL.** `DataTeller.configure`, `expose`, `refine` (segments, metrics, dimensions, synonyms, labels).
  Registry object, no Rails magic yet.
- **T07 Mandatory tenant.** Boot fails without `c.tenant`. `[sec]`
- **T08 Schema generation from DSL.** Build the LLM JSON schema from the registry (enums of declared names only).

## M2 — Evaluation harness (before any LLM call)

- **T09 Eval dataset v0.** 40 French questions → expected IR, including traps: synonyms, ambiguity,
  out-of-scope, relative dates, cross-tenant attempts. Split: 30 dev / 10 held-out (never inspected while iterating).
- **T10 Scorer.** Per-field scoring (dataset, metric, filters, group_by, clarification decision). Results saved per run (JSON), diffable.
- **T11 `rake data_teller:eval`.** Prints a table + delta vs previous run.

## M3 — LLM baseline

- **T12 Provider client.** Raw HTTP, structured outputs with the generated schema, timeouts, retries, token + latency logging.
  `[dep]` HTTP client only if needed (Faraday); no LLM framework. `[sec]` API key via credentials.
- **T13 Naive pipeline.** Whole registry in the prompt. First scores recorded as the baseline in an ADR.
- **T13b Minimal ask page (pulled forward from T30).** ERB + Hotwire, dev-only mount in the dummy app: question box,
  structured query shown as JSON, result. Exists so the article series has real screenshots/GIFs from part 4 on.
  Herb (lint ERB) only as a dev tool, flagged `[dep]` when added. No Phlex.
- **T14 Prompt iteration log.** Each prompt change = one eval run, one commit.

## M4 — Retrieval (RAG)

- **T15 Indexable documents.** One document per dataset / metric / dimension / segment (label + synonyms + description), content hash.
- **T16 Embeddings pipeline.** Embed at deploy, only changed hashes. `[dep]` embeddings provider (API or local Ollama).
  `[perf]` question embeddings cached; never embed rows. `[sec]` only declared labels leave the app.
- **T17 Retrieval A — vectors only.** pgvector cosine. Metric: recall@k on the eval set (retrieval scored independently).
- **T18 Retrieval B — hybrid.** `tsvector` (French config) + vectors, RRF fusion. Compare with A on identical questions.
- **T19 Retrieval-scoped prompt.** Only retrieved items go into the schema/prompt. Compare vs T13 baseline (accuracy, tokens, latency).
- **T20 Dynamic few-shot.** Validated past questions retrieved as examples. Measure the gain.
- **T21 (optional) Reranking.** Only kept if the eval shows a gain.

## M5 — Safe execution

- **T22 IR validator.** Reject unknown dataset/metric/dimension/role, bad operators, type mismatches. Property-style specs. `[sec]`
- **T23 Compiler IR → ActiveRecord.** Bound parameters only (no interpolation), whitelisted operators. `[sec]`
- **T24 Tenant path + injection.** Infer/declare path through `belongs_to`, apply `joins` + `where` on every query,
  including group_by through associations. Specs: default_scope, soft-delete, STI, nullable tenant. `[sec]`
- **T25 Execution guards.** Read-only role/transaction, statement timeout, row limit, group_by cardinality cap. `[perf]` `[sec]`
- **T26 Relative dates + tenant time zone.** `today/tomorrow/last_month/...` resolved in the compiler, never by the LLM or a lambda.
- **T27 Value resolution.** Entity linking for values ("commandes de Dupont"): local fuzzy match (ILIKE/trigram), ambiguity → clarification.
  Documents explicitly what the question text may leak to the provider. `[sec]`

## M6 — Trust UX

- **T28 Deterministic explanation.** i18n templates from the IR; user values escaped (XSS). `[sec]`
- **T29 Clarification + refusal.** IR can return `clarify` (with options) or `out_of_scope`; scored in eval.
- **T30 Engine endpoint + production UI** (builds on T13b). `mount DataTeller::Engine`, one Hotwire page, result as number/table.

## M7 — Hardening

- **T31 Adversarial suite.** Prompt injection, cross-tenant ids, oversized inputs; shared examples users run against their own config. `[sec]`
- **T32 Per-tenant/user rate limit + token budget.** `[perf]` `[sec]`
- **T33 Pundit adapter.** `policy_scope` applied, `unscope(:order)` on aggregates; isolation check as CI shared example, **not at boot**. `[sec]`
- **T34 Install generator.** Infer dimensions, labels, joins, tenant path, hidden columns (encrypts, password/token/email/…).
  Core piece since ADR 0001 D4 (paths are derived from exposed models/columns): consider pulling it forward after M5.

## V1 (after M7)

Roles + PII masking · saved/shared questions as RAG examples · 👍/👎 feedback → eval dataset ·
audit log + token cost per tenant · answer cache · unanswered-question log with declaration suggestions.

## V2

Scheduled reports · threshold alerts · whitelisted actions with human confirmation · embeddable component.

---

## Suggested order

M0 → M1 → **M2** → M3 → **M4** → M5 → M6 → M7. The learning value is concentrated in M2–M4;
M5 is where the product becomes safe. Do not skip the baseline (T13): every later claim is relative to it.
