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

## Pending

- D2 value typing (literal / relative / lookup)
- D3 boolean logic in filters
- D4 joins via dotted dimensions
- D5 structured clarify / out_of_scope
- D6 number of metrics per query
