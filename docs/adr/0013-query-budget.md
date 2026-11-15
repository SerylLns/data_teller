# ADR 0013 — The query budget: a time per question, and an optional cost estimate

Status: accepted (2026-11-15)

Context: T38. ADR 0005 D3 sets a `statement_timeout`, and Postgres applies it to each statement, not to a question. A question can be several
statements: `compare` runs two plans (ADR 0005 D4), and a protected answer counts its hidden groups with a second query (ADR 0012 D3). A protected
`compare` is four statements, so up to four times the timeout, 20 s by default, with a pooled connection held all along. A timeout also stops a
heavy query only once it has used the database for that long. The roadmap planned an `EXPLAIN` cost check to refuse such a query before it runs.

## D1 — Both: a time budget per question always, a cost estimate as an option (decided, "C")

- **Why:** the time budget is exact, cheap and needs no tuning: it closes the 20 s hole for every integrator. A cost estimate is in the planner's
  units, which depend on the database's statistics and settings and have no fixed relation to seconds; a threshold set by default, or without
  the integrator's own data, would either refuse good questions or never fire. So it is off until the integrator sets it, with a tool to choose it
  (D4).
- Rejected: the cost estimate alone (A: nothing bounds a question whose estimate is wrong, and the 20 s hole stays); the time budget alone (B:
  a heavy query still runs until the timeout before it is refused).

## D2 — The time budget: the time left, set again before each statement (decided, "B1")

`ReadOnlyExecution` takes a deadline when it starts, now plus the budget. Before each statement a plan sends, it sets `SET LOCAL statement_timeout`
to the time left; with no time left, the question is refused with `query_timeout` and the statement is not sent.

- **Why:** the question as a whole fits in the budget, whatever its number of statements, and a fast first statement leaves its time to the next.
  Compilation shares the budget: a scope's code runs under the time left, and anything it overspends shows at the next statement.
- **The setting is renamed `query_timeout`**, like the refusal it gives, 5 s by default. `statement_timeout` would now say "per statement" and mean
  "per question". The gem is not published, so nothing breaks.
- **The isolation kit** gives the same budget to each query it runs.
- **Cost:** one more `SET` round trip per statement, four at most for a protected `compare`.

Rejected: Postgres' own `transaction_timeout` (B2, Postgres 17 and later: it ends the session with a FATAL error rather than cancelling the
statement, so the pool loses the connection and the error is not a `query_timeout`); the budget split evenly between the statements (B3: a fast
statement wastes its share, a slow one is cut early).

## D3 — The cost estimate: the sum over the question, before anything runs (decided, "A1")

With `max_query_cost` set (nil, off, by default), every statement of the question is planned with `EXPLAIN (FORMAT JSON)` before any is run, and
the sum of their plans' `Total Cost` is compared to the setting. Over it, the question is refused with a new engine reason, `too_complex`.

- **Why the sum:** the setting then means what it says for a question, as the time budget does. The compiler knows every statement up front: the
  answer, the count of hidden groups, the previous period of a `compare`.
- **Why before anything runs:** a refused question then costs planning only, a few milliseconds and no row read.
- **Where:** in the same transaction, under the same database role and row security (ADR 0005 D6, D7), so the plan estimated is the plan that
  would run.
- **`too_complex`** is found by the engine, like `too_many_groups`, and stays out of `query_v1.json`: the LLM cannot pick it. Its sentence comes
  from the translations: "This question would be too heavy to answer. Try narrowing it down."
- **Cost:** one `EXPLAIN` round trip per statement, only when the setting is on.
- **Limits:** an estimate can be wrong by orders of magnitude, mostly on row counts. A low estimate lets a heavy question through, and the time
  budget of D2 stops it; a high one refuses a question that would have been fast.

Rejected: a threshold per statement (A2: a protected `compare` would pass at four times the threshold); checking each statement just before it
runs, adding as it goes (A3: the first statements would have run for nothing when a later one goes over).

## D4 — Choosing the threshold: `rake data_teller:costs`, estimates next to real durations (decided, "T2")

The task runs the isolation kit's queries (one per declaration, ADR 0011 D4) as the same tenants, with `EXPLAIN (ANALYZE, FORMAT JSON)`, and
prints each query's estimated cost next to its real duration, sorted by cost, with the current `max_query_cost` if one is set. The integrator
sees where the durations take off and sets the threshold below that point.

- **Why real durations:** a cost alone means nothing to the person choosing the threshold; next to milliseconds, on their own data, it does.
- **Safe on a copy of production:** the queries run as the kit's do, read-only, in a transaction that is always rolled back, under the budget of
  D2. The report holds dataset names, query shapes, tenant keys, costs and durations, never a value.
- **Limits:** the kit's queries are simple, one grouping or one filter or one segment each. The heavy questions combine them, with `compare` on
  top: the tool gives the scale of the costs, not the worst case. Leave a margin; the time budget stays the net.

Rejected: estimates only (T1: numbers with no unit the integrator can relate to); an option of the isolation kit, `COSTS=1` (T3: two subjects in
one report, and the kit's is meant for CI).
