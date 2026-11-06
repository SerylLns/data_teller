# ADR 0004 — Declaration DSL

Status: accepted (D1-D6 decided one at a time)

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
- A segment never contains **code** that computes a date (no lambda, no `Date.tomorrow`): that would ignore the tenant time zone.
  A declarative relative offset (`created_before: { days_ago: 30 }`) is data, resolved by the compiler with the tenant time zone, and is allowed.
  Period expressions like "tomorrow" stay in `period`, not in segments.

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

## D4 — Segments: declarative by default, guarded escape hatch to a scope (decided, "C")

```ruby
segment :paid,    where: { status: :paid }
segment :overdue, where: { status: :pending, created_before: { days_ago: 30 } }
segment :vip,     scope: :vip_customers      # escape hatch, checked at boot
```

- The declarative form is the norm: analyzable, explainable from its definition, no surprise with the tenant scope.
- `scope:` reuses an existing ActiveRecord scope to avoid duplicating business logic. Accepted only if it takes no argument and
  has no `order` / `limit` / `group` / `select` and no relative date. Its label comes from I18n (its content cannot be explained).
- **The boot checks are a lint, not a security validation.** They catch accidents; a scope is arbitrary code and can be wrong
  or hostile. Documentation must say so plainly.
- The real boundary: the compiler applies the tenant scope **last**, on top of the segment, so a scope calling `unscoped` or
  `unscope(where: ...)` cannot remove the tenant condition; a structural check asserts the tenant predicate is present in the
  final relation; the DB-level role (T37) and optional RLS (T39) back it up.
- Security Test Kit: includes fixtures with hostile scopes (`unscoped`, `unscope`, `or`, `rewhere`) and segments flagged as
  less verifiable.

Why: keeps the DRY promise of the README where possible without making arbitrary code a trusted part of the query.

Rejected: scopes by name only (unanalyzable code, unexplainable, relative dates ignoring the tenant time zone);
declarative only (forces rewriting every business scope).

## D5 — Roles and permissions: declarative roles for concepts, Pundit for rows (decided, "C")

Principle: **DataTeller controls what users can ask; Pundit controls which records they can access.**

| Level | Responsible |
|---|---|
| Dataset, metric, dimension, segment | DataTeller DSL (`roles:`) |
| Accessible rows | Pundit (`policy_scope`, T33) |
| Tenant isolation | DataTeller (compiler) + database (role, optional RLS) |

Pundit can never widen the tenant scope: the tenant condition is applied last, on top of everything else.

Rules:
- Every dataset declares `roles:` explicitly (boot error otherwise). Metrics, dimensions and segments inherit the dataset's roles and can
  only **narrow** them, never widen. `sensitive:` dimensions require an explicit `roles:`.
- Roles come from the host app (`c.roles { |user| ... }`). `nil` or a resolver error -> no access (fail closed). Unknown role -> no extra
  permission. Several roles -> union. Permissions are recomputed on every request.
- A permission applies to every use of a name, not only display: filtering, grouping, ordering/top-N and period all need it
  (filtering on a hidden dimension would reveal its values by bisection).
- Derived metrics (`ratio:`) are visible only if all their dependencies are visible in the user's effective (unioned) catalog.
  Otherwise `count` + `avg_basket` would reveal `revenue`.
- Segments inherit the permissions of the columns they reference. A `scope:` segment cannot be analyzed, so it must declare `roles:` explicitly.
- A dotted dimension inherits the permissions of its target column (ADR 0001 D4).
- **One choke point:** a per-request "visible catalog" object, used by schema generation, retrieval, suggestions, explanations and the
  validator, so consistency across the whole chain is testable by the Security Test Kit.
- The LLM schema is generated per role (forbidden names are absent), but **that is not a security boundary**: the validator always
  re-checks permissions server-side. The schema/catalog cache is keyed by the fingerprint of the effective permissions plus the registry
  version, never by user id.
- Leak surfaces to cover with the same catalog: question suggestions, query history, error messages, search results, explanations of
  derived metrics, saved questions (re-validated against the viewer's catalog), the unanswered-question log (admin only), and dynamic
  few-shot examples (T20), which must be filtered by tenant AND by the role's catalog (examples can contain forbidden metric names or customer names).
- Refusals never reveal that a forbidden resource exists (ADR 0001 D5): unauthorized and unknown give the same answer.

Why: functional authorization and row authorization are different problems; each tool handles the one it is good at, and nothing in the DSL is
arbitrary code.

Performance: the catalog is set operations, cached by fingerprint.

Rejected: everything delegated to Pundit (rules scattered across policies, not validatable at boot, not testable by the kit);
free lambdas in the DSL (arbitrary code); "no `roles:` means visible to all" (too permissive).

## D6 — Registry and boot validation: fail hard by default, configurable, always fail closed (decided, "A with setting")

- The registry holds everything the DSL declared. It is validated once at boot (rebuilt on reload in development through
  `to_prepare`), then **frozen**: no runtime mutation, safe across threads. It carries a version, reused in the cache fingerprint (D5).
- Validation collects **all** errors and reports them together. Checks: `c.tenant` defined; a tenant path found for every exposed
  model (ambiguous = error); explicit `roles:` on every dataset; at most one `time:` dimension per dataset; no cycles between derived
  metrics; existing columns and associations; `scope:` segments pass the lint (D4); sensitive dimensions justified; missing I18n keys
  are warnings.
- Setting: `c.on_invalid_config = :raise | :disable`, default `:raise`.
  - `:raise`: the app refuses to boot (consistent with the mandatory tenant).
  - `:disable`: the engine is switched off (routes answer 503, the palette is not rendered) with a loud log, so a side feature cannot
    take the host app down. Both modes fail **closed**, never open.
- `rake data_teller:check` runs the same validation in CI before deployment.

Why: a broken exposure config must never go unnoticed, and the choice between availability of the host app and strictness belongs to
the integrator, with the safe option as the default.

Performance: validation runs once at boot (or on reload in development).

Rejected: lazy validation on first use (errors surface to end users in production); hard failure with no opt-out (a secondary
feature can block the host app's boot).

## Status

All decisions D1-D6 are taken. Next: implement T06 (DSL and registry), T07 (mandatory tenant), T08 (schema from the registry).
