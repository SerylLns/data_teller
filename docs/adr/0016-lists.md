# ADR 0016 — Lists: an answer that shows rows

Status: accepted (2026-11-24)

Context: T44. In the first real integration, the author's first question that was not a count was "show me the ... arriving tomorrow", and
it got the generic refusal. DataTeller answers with aggregates only (ADR 0004 D2): a list was out of scope, which kept every rule about what
a user may see at the level of a number. Users ask for lists before they ask for numbers; a palette that refuses them looks broken.

A list is the step the aggregate rules guard against: `group_by customer_id` is already treated as "a list in disguise" (ADR 0004 D3), and
`min_group_size` exists because a small group is one person (ADR 0012). So a list is opt-in, refused where the aggregates are protected,
and goes through the same validator, compiler and tenant filter as any answer.

## D1 — A fourth branch of the query: `list: true` instead of `metric` (decided)

```json
{ "version": 1, "intent": "answer", "dataset": "orders", "list": true,
  "columns": ["ordered_at", "customer.city", "status"],
  "period": { "dimension": "ship_on", "range": { "relative": "tomorrow" } },
  "filters": [{ "segment": "paid" }],
  "order_by": { "by": "dimension", "dimension": "ordered_at", "dir": "asc" }, "limit": 20 }
```

- An answer still: the palette, the eval's error classes and the trace key on `intent`, and a list is what the user asked for, not a new kind
  of exchange. `period`, `filters`, `order_by` and `limit` keep their meaning; `group_by` and `compare` have none for rows and are refused.
- `order_by.by` names a dimension, not a metric; `limit` caps the whole list ("the last 10 orders"), the pages below cut it.
- The schema stays version 1: the branch is added, no existing query changes meaning.

Rejected: `intent: "list"` (every consumer of `intent` changes: the palette, the eval's classes and severities, the trace); a reserved
`metric: "rows"` (a magic name that can collide with a declared metric, and rows become special cases inside the aggregate code).

## D2 — The model picks the columns, among a dataset that opted in (decided)

```ruby
DataTeller.refine Order do
  list default: %i[ordered_at status channel ship_on]
end
```

- **Opt-in per dataset:** without `list`, the dataset cannot be listed. A list shows combinations row by row (a date, a customer's city, a status)
  that no aggregate shows; the integrator decides where that is fine, as they decide what to expose.
- **`columns`, chosen by the model**, are dimensions of the dataset the role sees, paths included, 8 at most; without `columns`, the
  declared `default`. A column the role does not see is unknown, as anywhere else (ADR 0001 D5). The defaults are checked at boot like
  any reference to a dimension, and `rake data_teller:check` grants their columns (ADR 0005).
- **`sensitive` dimensions** cannot be in `default` and cannot be listed unless their own `roles:` allow the asker: a list reads the value
  itself, as `min`/`max` do (ADR 0004).
- **Paths join as in aggregates** (inner joins, each with its tenant filter): a row with no parent is left out of a list showing that parent's
  column. That is the open item on optional `belongs_to` (found in the same integration), to decide once for both.

Rejected: columns declared only, the model choosing nothing (less to score, but "show me the orders with their channel" cannot be answered);
every visible dimension with no opt-in (every exposed dataset becomes listable row by row on a gem update, without the integrator deciding it).

## D3 — Refused on a dataset protected by `min_group_size`, except for the roles it exempts (decided)

If any dataset the list reads, the one asked or one joined by a column or a filter path, declares `min_group_size`, the list is refused for
every role not in that dataset's `except:`.

- **Why:** a list is rows one by one, the very thing the threshold prevents. The exempt roles already see groups of one; nobody else gets a
  way around it. Fails closed: a role added later cannot list people until someone exempts it.
- The refusal is `unsupported_query` with its own code in the trace, so the integrator can tell it from a mistake.

Rejected: the protected dataset's columns removed from the list (a row is still one person, and a date with a status often finds them).

## D4 — Pages of 50 with a cursor; the palette sends the query back (decided)

- **Page size:** `c.max_list_rows`, 50 by default, configurable. The first page comes with the total (one `count` more, in the same
  read-only transaction); "51-100 of 128".
- **Order:** the query's `order_by`, else the dataset's default time dimension, descending; then the primary key, so the order is total.
  Nulls last.
- **Keyset, not offset:** the next page is asked with a cursor, the order value and the primary key of the last row shown
  (`after: ["2026-11-25T10:00:00Z", 18342]`). Rows added between two pages neither repeat nor get skipped, and a far page of a large table costs
  what the first one does. Cursor values are checked against the column's type and bound, as any filter value.
- **Stateless:** the palette sends the validated query back with the cursor to `POST /rows`. The server validates it again against the user's
  catalog, exactly as it validates the model's output: the model's output is already treated as hostile (it can be steered by the question),
  so a query written by the user can do nothing the model could not be steered into. `/rows` accepts list queries only, never calls the
  provider, and runs under the same timeout, cost budget and database role.
- **Ruby API:** `DataTeller.rows(query, user:, after:)` for a host that builds its own view (ADR 0010 D1).

Rejected: `max_rows` (1,000 rows in a palette, and nothing says the list is cut); the validated query kept in a server cache behind a token
(state: expiry, several workers, a shared cache); `OFFSET` (rows skipped or repeated when data arrives between pages, slow far pages).

## Consequences

- Query schema: the `list` branch; the generated provider schema (T08) offers it only when the role sees a listable dataset, with `columns`
  restricted to that role's dimensions.
- The prompt's catalog says which datasets can be listed and their default columns. A prompt change: measured with the eval before and after.
- Validator: `list` without `metric`, no `group_by` nor `compare`, columns visible and at most 8, `order_by` on a dimension, the D3 refusal.
- Compiler: a list plan (select, keyset, total), its rows decoded like groups (enum names, dates in the tenant's time zone).
- `rake data_teller:isolation` probes a list on each listable dataset, every row traced to its owner (ADR 0011); `rake data_teller:costs` too.
- Palette: a table, the total, "more" fetching the next page from `/rows`.
- Eval: `list` and `columns` compared (columns as a set, absent equal to the default), questions tagged `list` in English and French.
- Not decided here: links from a row to the host's own page; labels for column headers (open, same integration).
