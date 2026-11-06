# ADR 0004 — Declaration DSL

Status: in progress (decisions are taken one at a time)

Context: the developer declares what is exposed (datasets, metrics, dimensions, segments, vocabulary).
Nothing is exposed until it is in a visible, versioned file (ADR 0001, README principle).

## D1 — Syntax and layout: `refine` blocks, one file per dataset, vocabulary in I18n (decided, "A+")

- Syntax: `DataTeller.refine Order do ... end` blocks (segments, metrics, dimensions).
- Layout: global config in `config/data_teller.rb` (tenant, LLM, list of exposed models); one file per dataset in
  `config/data_teller/<dataset>.rb`. A new exposed model shows up as a new file in the diff. These are configuration
  files loaded like initializers (reloaded through `to_prepare` in development, validated at boot), not autoloaded app code.
- Vocabulary (labels, synonyms) lives in I18n files, one per locale (`config/locales/data_teller.<locale>.yml`).
  The DSL holds structure and logic; short inline `synonyms` stay allowed. Long synonym lists are never sent whole to the
  LLM: retrieval selects the relevant ones.
- The install generator (T34) writes one file per model plus the locale files.

Why: keeps the explicit, reviewable exposure; scales to many models without a 600-line initializer; separates logic from
language-dependent vocabulary; consistent with labels already coming from I18n.

Security/performance: files are developer-authored Ruby loaded like initializers (same trust level, no user input);
the registry is built at boot, negligible runtime cost.

Rejected: concern inside each model (touches models, scatters the exposed surface, contradicts the explicit-exposure principle);
a single initializer for everything (unreadable beyond a few models); autoloaded `app/data_teller/` (code-like, harder to review as config).
Possible later: support the autoloaded layout without breaking this one.

## D2 — Metrics: closed aggregation vocabulary, segments for business logic, `ratio:` for derived metrics (decided, "B")

```ruby
metric :count                                    # implicit
metric :revenue,    sum: :total_cents, format: :money
metric :avg_basket, ratio: [:revenue, :count]    # division guarded against zero by the compiler
metric :customers,  count_distinct: :customer_id
```

- Aggregations are a closed set: `count`, `sum`, `avg`, `min`, `max`, `count_distinct`. A metric never contains free code.
- Business logic lives in segments (e.g. "to ship tomorrow" = segment `paid` + period `ship_on: tomorrow`), not in metrics.
- Four distinct responsibilities: metric (what is measured), segment (reusable business definition, developer-declared),
  filter (dynamic condition, LLM-filled and validated), period (time, LLM-filled and validated; ADR 0001 D1).
- A segment never contains a relative date ("tomorrow", "last month"): time is resolved by the compiler with the tenant time zone.

Why: validated, explained and tested by the compiler alone; no way for a metric to bypass the tenant scope or read a hidden column;
consistent with ADR 0001 D6 (one metric per query, derived metrics declared by the developer).

Performance: `avg` and `count_distinct` cost more than `count`; the complexity budget (T38) can flag heavy metrics.

Rejected: free lambdas in metrics (date frozen at load time, tenant time zone ignored, arbitrary code, not describable in one sentence);
aggregations only with no ratio (cannot express average basket without a developer-written query).

## D3 — Dimensions: type inferred from the column, explicit allowlist, capability flags (decided, "A")

```ruby
dimension :status                          # enum inferred from the model; values and labels via I18n
dimension :ship_on, time: true             # default time dimension of the dataset (at most one)
dimension :name, lookup: :trigram          # entity resolved locally (ADR 0001 D2)
dimension :city, group: false              # filterable but not groupable
dimension :customer_id, group: true, max_groups: 20   # high cardinality: explicit opt-in
```

- Types come from ActiveRecord (date, enum, string, number, boolean) and can be overridden. Enum values are not copied into the DSL.
- Every exposed dimension is a named line in the file, so nothing becomes queryable without a diff.
- Flags: `time:`, `lookup:`, `filter:`, `group:`, `max_groups:`, `sensitive:`.
- Sensitive names (`email`, `phone`, `token`, `password`, `iban`, ...) are refused unless explicitly forced with `sensitive: true` and a role.
- A dataset has one default time dimension; if several are plausible for a question, it becomes a clarification (ADR 0001 D5).
- A dotted dimension (`customer.city`) inherits the rights of its target column (ADR 0001 D4).

### Cardinality rule (performance and privacy)

Grouping by a high-cardinality dimension is a performance risk and a privacy risk: `group_by customer_id` with a count is a
list of customers in disguise, i.e. row-level disclosure presented as an aggregate.

- **Classification.** Enums and booleans are low cardinality. Foreign keys, ids, free strings and names are high cardinality.
  Dates are bounded by period and granularity. The install generator can read `pg_stats.n_distinct` to suggest the class.
- **Default.** `group` is allowed by default only on low-cardinality dimensions; high-cardinality ones need `group: true`
  with an explicit `max_groups` (global default configurable, e.g. 50).
- **Enforcement at execution.** The grouped query runs with `LIMIT max_groups + 1`; if the extra row appears the result is
  truncated to the top N (a high-cardinality `group_by` requires `order_by` and `limit`, otherwise it is refused).
- **Time series.** A date granularity over a long period is capped (a maximum number of points, e.g. 366); beyond it the query is refused.
- **Two group_by.** The cap applies to the product of both dimensions, so two high-cardinality dimensions cannot be combined.
- **Privacy.** `min_group_size` (T36) applies per group on top of this: small groups are suppressed even within the top N.
- **Refusals** use the same structured payload as ADR 0001 D5. Open point: reuse `unsupported_query` or add a dedicated
  reason (e.g. `too_many_groups`) to the closed list; decide before the validator ticket (T22).

Why: explicit exposure kept, types not duplicated, and the cost and leak potential of grouping is a declared, enforced limit
instead of a hope.

Rejected: fully explicit types and enum values (verbose, drifts from the model); exposing every column minus a hidden list
(a new column becomes queryable without a diff).

## Pending

- D4 segments (reuse existing scopes by name vs inline definitions)
- D5 roles and permissions in the DSL
- D6 registry object and validation at boot
