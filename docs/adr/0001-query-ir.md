# ADR 0001 — Structured query format (IR)

Status: in progress (decisions are taken one at a time)

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

## Pending

- D3 boolean logic in filters
- D4 joins via dotted dimensions
- D5 structured clarify / out_of_scope
- D6 number of metrics per query
