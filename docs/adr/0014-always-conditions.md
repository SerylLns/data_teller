# ADR 0014 — Conditions always applied: `always` on a dataset

Status: accepted (2026-11-23)

Context: T42. A trial integration showed it. An app often hides some rows on every screen without a `default_scope`: a status its policy scope
leaves out, records archived with `discard`, which has none by design. DataTeller counted them: on fake data, the total of such a table was off by
exactly the hidden rows. Nothing leaks, every row belongs to the tenant, but the number is one no screen of the app gives. Today the only tool is
a segment, which the model has to pick on every question; a `where:` segment cannot say "not" either, so leaving out one status of many means
listing all the others.

## D1 — A dataset condition in the DSL (decided, "A")

```ruby
DataTeller.refine Order do
  always scope: :not_draft        # the negative scope Rails defines for `enum :status`
  always where: { archived: false }
end
```

`always` takes the grammar of a segment, `where:` or `scope:`, without a name or `roles:`: it is not something to choose, and it applies to
everyone. A dataset can have several, all of them apply.

- **Why:** the right number then depends neither on the model picking a segment nor on an integrator remembering a trap. It covers `discard` and
  policy-only conditions alike, and goes through the checks a segment already has: a scope is called read-only and held to the condition
  whitelist (ADR 0004 D4), a `where:` key must be a column, the columns are granted to the reader role (ADR 0005).
- **Not a security boundary:** it only narrows the rows. The tenant filter still comes last and does not depend on it (ADR 0005 D1).
- **Not shown to the model:** the catalog and the generated schema do not list it, there is nothing to choose.
- **A relative offset (`{ days_ago: 30 }`) is refused** at declaration: a rule of the business does not move with today's date.

Rejected: no gem change, a reporting subclass with a `default_scope` per table (B: one more model per table, edge cases with STI and associations,
and nothing tells the integrator they need it); a segment marked `default: true` (C: a segment is a choice the user makes, a business rule is not
switched off; mixing them blurs the catalog).

## D2 — Applied on every table the query reads, joins included (decided)

The compiler adds the conditions of every dataset the query touches: the one asked, the ones joined by a dimension path or a metric path.

- **Why:** as a `default_scope`, which Active Record applies to a join. Otherwise "line items by order status" would show a group for the
  hidden status that "orders by status" does not.
- **Not on the tenant sub-query.** Who owns a row does not depend on a condition of its parent, the same rule as for a soft-delete `default_scope`
  (ADR 0005 D1). So, as with a soft-delete, a total and a breakdown through that parent can disagree: the total keeps a line item whose order is
  hidden, the breakdown by order status leaves it out.
- Each condition is built on its own table and wrapped in its own parentheses: a `where:` hash handed to the relation would be read against the
  dataset's table.

Rejected: on the dataset asked only (simpler, but the breakdown through a join shows what the dataset hides).

## D3 — No negation in `where:` for now; a scope says it (decided)

`where.not` goes in a named scope of the model. The whitelist already accepts `!=` and `NOT IN`.

- **Why:** no new grammar, the same as segments. A `where:` hash already uses nested hashes for relative offsets, so `{ not: ... }` would be read
  two ways.
- **Price:** the host adds a scope to its model, except on an enum: Rails defines `not_<value>` for each value, as `:not_draft` above, so
  the case that raised this ADR needed no code in the host. A second case asking for it brings back a `where_not:`, for
  segments as well.

Rejected: `where_not:` (one more key to validate, and segments would need it too to stay alike); `{ not: ... }` inside `where:` (ambiguous with
the relative offsets).

## Consequences

- `Dataset#always`, a list of `Always` (`where`, `scope`), part of the registry fingerprint only when present, so that existing fingerprints stay.
- The boot (`Validator`, `ModelValidator`) refuses a built-in method or an undeclared scope; `rake data_teller:check` (`SchemaValidator`) calls
  the scope read-only and checks `where:` columns, as for segments.
- `ReaderGrants` grants the columns they compare.
- The isolation kit and the cost report go through the compiler, so they run with the conditions.
