# ADR 0005 — Compiler: from a validated query to ActiveRecord

Status: accepted

Context: the compiler is where a query becomes SQL, so it is where tenant isolation is actually enforced.
Principle: the tenant filter is added by code the LLM and the declarations cannot influence, and it is checked before anything runs.

## D1 — The tenant filter is a sub-query, built in one place (decided, "A")

```sql
-- tenant_path :account
WHERE orders.account_id = $1
-- tenant_path :order, :account
WHERE line_items.order_id IN (SELECT orders.id FROM orders WHERE orders.account_id = $1)
```

- One method builds it, for any table, at any depth. It uses no join, so it cannot duplicate rows or conflict with the query's own joins.
- Every table touched gets its own filter: the dataset, each table joined for a path, each table a metric path goes through. An order pointing by mistake at another
  tenant's customer does not bring that customer's name out.
- The sub-query is `unscoped`: it answers "who owns this row", which a soft-delete `default_scope` on the parent must not change. The main relation keeps its default scopes.
- Order of construction: `default_scope` checked, conditions of `scope:` segments (`AND`, ADR 0004 D4), declarative segments and filters, then the tenant filters, then the grouping. Nothing that could remove a condition runs after them.
- A check then confirms each filter is in the final relation, and the query does not run otherwise. It proves the filter is there, not that it filters: that is what the whitelist on scopes is for.
- The tenant must be an instance of the class the path ends at, and every step a `belongs_to`, even though the boot checks it: comparing a customer id to `account_id` would read another account.

Why: this is where a mistake would be the worst bug of the project, so simplicity comes first.

Performance: possibly slower than a join, depending on the plan. Not measured; `EXPLAIN` comes with the complexity budget (T38), and this can be optimized without touching the rest.

Rejected: a join (natural SQL, often the fastest, but the filter gets mixed with the query's joins: a query that already joins `orders` for `order.status` would have to reuse that join without a mistake).

## D2 — Other compilation choices (defaults, not contested)

- **Values are bound parameters**, for every operator, including `gt` and `contains`. Column names come from the catalog, never from the query's text.
  The two literals that are not bound, a granularity (closed list) and a time zone (from `ActiveSupport::TimeZone`), are quoted: Postgres sees `date_trunc` in SELECT and GROUP BY as different expressions when they use different parameters.
- **Paths use `INNER JOIN`.** An order with no customer does not appear when grouping by customer, so a grouped total can be smaller than the overall total. It needs documenting for integrators. `is_null` on a path therefore means "the related row has no value", not "there is no related row".
- **`not_eq` and `not_in` follow SQL**: a row with no value does not match. "Orders not in Paris" leaves out customers with no city.
- **"The last 7 days" includes today**, on a rolling basis. "This month" covers the whole month, so that a future `ship_on` can match. `between` includes both ends. Weeks start on Monday.
- **Postgres only**, for `date_trunc` and `AT TIME ZONE`. pgvector requires it for retrieval anyway.
- **Bounded results.** A high-cardinality grouping is capped at `max_groups` (`default_max_groups`, 50) with the metric descending, per ADR 0004 D3. Any other grouped query is capped at `max_rows` (1,000).
  One extra row is fetched to know whether the result is `truncated`. A date series with no limit of its own is refused with `too_many_groups` rather than cut, beyond `max_time_points` (366) distinct dates or beyond `max_rows` rows.
  Dates, not rows: by status and by day, 90 days is 90 points on 450 rows (amended 2026-11-07, the first version counted rows against the date cap and ignored `max_rows`).
- **Joined tables are capped** at `max_joins` (5).
- **A ratio over a metric with a path is refused at boot.** The join would change what the denominator counts.
- **A metric path touches each table once, and never a `has_many :through`.** Columns and filters are built by table name, so a table met twice would be read under the wrong alias, and the table inside a `through` would have no tenant filter. Refused at boot.
- **A query reaches each table by one path only.** Each path is fine alone, but a dimension through `featured_product` and a metric through `line_items.product`
  would join `products` twice, and Rails aliases the second join: the sum and the tenant filter would read the first one. Refused per query, since a dataset can declare both (amended 2026-11-07).
- **A descending order puts `NULL` last**: Postgres puts it first, and a group with no value would take a slot of a top N.
- **Date grouping needs timestamps stored in UTC**, or a column with a time zone. With `default_timezone = :local` it is refused rather than shifted.

## D3 — Execution: read-only and timed out, enforced by the database (T25)

```sql
BEGIN
SET TRANSACTION READ ONLY
SELECT 1
SET LOCAL statement_timeout = 5000
-- compilation, then the query
ROLLBACK
```

- **Compilation runs inside**, not only the final query, because calling a scope runs its code.
- **Always rolled back.** Nothing was written anyway, and inside a host transaction this is a savepoint: releasing it would keep the read-only mode and the timeout for the rest of the host's transaction. A rollback restores both, and a failed query does not poison the host's transaction.
- **The database enforces it**, whatever the code tries, raw SQL and `SET TRANSACTION READ WRITE` included. A cancelled query gives its own refusal, `query_timeout`.
  `SELECT 1` is what makes the second part true (amended 2026-11-07): Postgres lets a top-level transaction go back to read-write until its first query, and a `SET` is not one.
  The specs missed it because transactional fixtures turn the guard into a savepoint; a spec now runs it outside any transaction.
- **A scope can still change its own `statement_timeout`** with `SET LOCAL`. It is the host's code, and nothing inside a transaction can forbid it.
- **Limits** are settings (`statement_timeout`, `default_max_groups`, `max_rows`, `max_time_points`, `max_joins`). A value that would mean "no limit", such as a timeout of 0, or under a millisecond, which rounded to 0, is a configuration error.

Performance: four more round trips per query (`BEGIN`, two `SET`, `SELECT 1`), and a `ROLLBACK`. Not measured.

Limit: this does not stop what a scope does outside SQL, and it only covers the connection of the dataset's model. The database role of T37 covers the rest of the writes at another level.

## D4 — `compare`: two full plans (T26)

- A comparison is two queries from the compiler, each with its own tenant filter and its own check, in the same read-only transaction. The second one is as much of a target as the first, so it gets nothing less.
- **Calendar units step back by calendar units:** last month against the month before, whatever their lengths. `last` steps back by its N, `on` and `between` by their length. `previous_year` takes the same dates a year earlier (February 29 gives February 28).
  The previous period's end is stepped back from the last day, not from the exclusive end, except for whole months (amended 2026-11-07): month ends clamp, so both ends moved by different
  lengths. On February 28, "the last month" counted January 29-31 in both periods; a year back, "yesterday" on March 1 compared one day with two. A rolling period now always
  ends where the current one starts, checked on every day of two years.
- **A period still in progress stops at today, on both sides.** On November 4, "this month" compares November 1-4 with October 1-4: 4 days against all of October would always look like a collapse. This also cuts future rows, such as a `ship_on` later this month. Without `compare`, "this month" keeps the whole month. The result carries both periods, so the explanation can state them (T28).
- **The result follows the current period:** its top N, with each group's previous value. The second query is narrowed to those groups rather than cut by rank, since a group's previous value must not depend on how it ranked then. A group that did not exist before gets 0 for a sum or a count, and no value for an average or a ratio. A group that only existed before does not appear.
- **A date group is refused:** October's weeks and September's weeks are different groups, and nothing lines them up.

Performance: two queries, so up to twice the cost, in one statement timeout each.

## Not implemented yet: refused, never approximated

- `{ "lookup": ... }` values (T27).
- Relative conditions in a segment, such as `{ days_ago: 30 }`: their exact syntax still has to be decided.
