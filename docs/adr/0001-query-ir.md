# ADR 0001 — Structured query format (IR)

Status: accepted (D1-D6 decided one at a time)

Context: the LLM never writes SQL. It fills a structured query validated against the
developer's declarations, then compiled to ActiveRecord. This ADR fixes the shape of that query.
Scope chosen: "option B" — single metric, filters, group_by, order_by, limit, period comparison, top-N.

## D1 — Time is a dedicated `period` field (decided)

`period` carries the time dimension and range. Date dimensions are rejected in `filters`.

Why: one code path for relative dates and tenant time zones, trivial `compare`
(shift the period), unambiguous "which date is the period" for the clarification step,
and time errors can be scored separately in the eval.

Consequences: each dataset declares a default time dimension. Questions needing two date
ranges (e.g. ordered in October AND shipped in November) are not covered; revisit with a
secondary period only if the eval shows the need.

Rejected: A (date as a regular filter — ambiguous `compare`, scattered date resolution),
C (both — two ways to say the same thing pollutes the eval).

## D2 — Typed values, entity references resolved locally (decided)

A filter value is one of: a literal (checked against the declared enum/type), a relative
date (only inside `period`), or `{ "lookup": "<text>" }` for entity references.
The LLM never produces ids.

The compiler resolves a lookup locally, inside the already tenant-scoped relation:
0 matches -> explicit "not found", N matches -> `clarify` with the candidates, 1 -> filter on the resolved id.

The resolver is configurable per dimension (`lookup: :trigram` at MVP, `:hybrid` — trigram + vectors —
from the retrieval milestone). Proper nouns favour trigram; semantic values ("chaussures" -> "Shoes")
favour embeddings. Entity resolution gets its own recall@k in the eval.

Consequences:
- Only dimensions declared `lookup` accept this type; enums accept only declared values.
- Security: lookup must run with the tenant scope applied (adversarial test: no cross-tenant names).
  Candidates are never sent to the LLM; a future opt-in per dimension (local model) stays out of MVP.
- Performance: one extra query before the main one; GIN trigram index needed on lookup columns
  (the install generator should warn when missing).

Rejected: raw string compare (misses case/accents, silent homonyms),
candidates in the prompt (sends customer names to the provider).

## D3 — Filters are AND-only, with `in` / `not_in` (decided)

`filters` is a flat list combined with AND. OR on a single dimension is expressed with `in`,
exclusion with `not_in`. OR across different dimensions is not supported: the developer
declares a segment for recurring cases, otherwise the user asks two questions.

Why: flat schema, no recursion, easy to validate, score and explain in one sentence;
end-user questions are overwhelmingly conjunctive.

Revisit: if the eval shows repeated cross-dimension OR questions, add a single-level `any_of`.
It is additive, so it does not break existing queries.

Rejected: full boolean tree (LLMs produce deep or wrong trees; validation surface explodes).

## D4 — Dotted dimensions derived from exposed models (decided, "A'")

The LLM references related data with dotted dimensions (`customer.city`). A path is available
only if (1) the association exists and (2) the target model is exposed and the column is an
exposed dimension there. Developers declare models and columns, never individual paths.
The compiler derives joins and applies the tenant scope on every joined table.

Guard rails:
- `belongs_to` (many-to-one) paths only at MVP; `has_many` data is reached through declared
  metrics (e.g. `items_sold: sum(line_items.quantity)`) to avoid duplicated rows and wrong counts.
- Max depth 2, capped number of joins per query.
- A path inherits the permissions of its target dimension, not only those of the starting dataset.
- Two paths leading to the same dimension fail at boot with a message; the developer disambiguates with an alias.
- Labels are derived from association + target label, overridable.

Consequences: the install generator becomes a core piece of the product (it prepares the exposed
models, columns, labels and hidden columns that paths rely on), not a nice-to-have.
Security test to add: a column hidden on its own model stays unreachable through any association.

Rejected: per-path manual declaration (too heavy for adopters), fully inferred paths
at runtime (exposes never-reviewed columns), LLM-chosen joins (SQL in disguise).

## D5 — Structured `clarify` / `out_of_scope`, no free text from the LLM (decided)

`intent` is `answer`, `clarify` or `out_of_scope`. The last two carry a typed payload:
`reason` from a closed list (e.g. `ambiguous_period`, `ambiguous_metric`, `ambiguous_entity`,
`unknown_dataset`, `not_a_data_question`) and, for `clarify`, `options` restricted to declared names
(checked by the validator, so the LLM cannot invent options).

The UI renders translated labels from the keys. No sentence shown to the end user comes from the LLM.
The compiler emits the same payload (e.g. a lookup with several candidates, D2), so the UI handles one case.

Why: deterministic and translatable explanations, no unverified LLM text shown to customers
(prompt-injection surface), scorable in the eval (decision, then reason, then options),
and a stable `reason` vocabulary that makes failures easy to debug and aggregate
(feeds the unanswered-question log).

Guard rails:
- Eval must also measure unnecessary clarifications on clear questions (a lazy model can always clarify).
- Security: `out_of_scope` never reveals that a forbidden resource exists; unauthorized and
  unknown both return `unknown_dataset`.

Rejected: free-text clarification written by the LLM (unverified content, untranslatable, unscorable),
two-call decide-then-write (extra latency and cost, templates already do the job).

## D6 — One metric per query, versioned format (decided)

`metric` is a single declared name. Derived metrics (e.g. `average_basket: revenue / count`)
are declared by the developer, never composed by the LLM. The query carries a `version` field
from day one.

Why: one value axis keeps the result shape (single value, series, table), the explanation and
the eval scoring simple; `order_by`, `limit` and `compare` stay unambiguous.

Revisit: if the eval shows frequent two-number questions, move to `metrics` (1 to 3) as format
`version: 2`, a clean schema change instead of a patch. Same approach as D3 (`any_of`).

Rejected: array of metrics at MVP (multi-column results, ordering ambiguity, score definition,
tendency of the model to stack metrics on simple questions).

## Status

All decisions D1-D6 are taken. Next: write the JSON Schema and fixtures (T05) from this ADR.
