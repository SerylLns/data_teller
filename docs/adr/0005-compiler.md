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
- **Bounded results.** A high-cardinality grouping is capped at `max_groups` (default 50) with the metric descending, per ADR 0004 D3. Any grouped query has a hard cap of 1,000 rows until T25 refines it.
  One extra row is fetched to know whether the result is `truncated`.
- **A ratio over a metric with a path is refused at boot.** The join would change what the denominator counts.
- **A metric path touches each table once, and never a `has_many :through`.** Columns and filters are built by table name, so a table met twice would be read under the wrong alias, and the table inside a `through` would have no tenant filter. Refused at boot.
- **A descending order puts `NULL` last**: Postgres puts it first, and a group with no value would take a slot of a top N.
- **Date grouping needs timestamps stored in UTC**, or a column with a time zone. With `default_timezone = :local` it is refused rather than shifted.

## Not implemented yet: refused, never approximated

- `compare` (rest of T26).
- `{ "lookup": ... }` values (T27).
- Relative conditions in a segment, such as `{ days_ago: 30 }`: their exact syntax still has to be decided.
