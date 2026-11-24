# Configuration and checks

What the [quick start](../README.md#try-it-in-your-app) leaves out. A full reference of every keyword and setting is planned (T41).

## Time zone and language

- `time_zone { |account| account.time_zone }` in `c.tenant` sets what "today" means for a tenant.
- `c.locale { |user| user.locale }` sets the language of the palette. English and French are included.

## How heavy a question may be

```ruby
c.query_timeout = 5           # seconds for a whole question, every statement included (the default)
c.max_query_cost = 20_000     # an example, off by default: choose yours with rake data_teller:costs
```

`query_timeout` bounds a question, not each statement: a `compare` or a protected answer runs up to four, and they share the time. With `max_query_cost`, every statement of a question is planned with `EXPLAIN` before any runs, and a question whose estimated cost adds up to more is refused without reading a row. The cost is in the planner's units, which depend on your data and settings, so there is no default ([ADR 0013](adr/0013-query-budget.md)).

## Lists: answer "show me the ..." with rows

```ruby
# config/data_teller/orders.rb
DataTeller.refine Order do
  # ...
  list default: %i[ordered_at status ship_on]
end
```

A dataset with `list` can be listed row by row; without it, a question asking for rows is refused. The model picks up to 8 columns among the dimensions the role sees, paths included, and `default` is what a list that names none shows. A sensitive dimension can't be a default. Rows come 50 at a time (`c.max_list_rows`), with the total, newest first on the default time dimension unless the question gives an order. A list is refused on a dataset where `min_group_size` applies to the role, since a row is a group of one ([ADR 0016](adr/0016-lists.md)).

## Hide small groups from some roles

```ruby
# config/data_teller/customers.rb
DataTeller.refine Customer do
  roles :admin, :support
  tenant_path :account
  min_group_size 5, except: :admin

  dimension :acquisition_channel
end
```

On a dataset that describes people, a group of fewer than 5 rows is hidden from every role not named in `except:`, in any query that reads the dataset, joins included. The answer says how many groups were hidden, never which. A single number under 5 is refused, zero included: if 0 were shown, "hidden" would mean "at least one". `of: :customer` counts the distinct values of a direct `belongs_to` instead of rows, so that twelve orders from one customer count as one ([ADR 0012](adr/0012-aggregate-disclosure.md)).

## Leave out rows your app always hides

```ruby
# config/data_teller/orders.rb
DataTeller.refine Order do
  roles :admin, :support
  tenant_path :account
  always where: { archived: false }
  always scope: :not_cancelled   # the negative scope Rails defines for `enum :status`
end
```

For rows your app hides on every screen without a `default_scope`: archived with `discard`, or a status left out by a policy scope. Every query that reads the dataset gets the condition, joins included, and the model never sees it. It takes a segment's `where:` or `scope:`, and the same checks apply. A "not equal" goes in a scope; on an enum, Rails already defines one per value ([ADR 0014](adr/0014-always-conditions.md)).

## Checks: the rake tasks, the isolation kit and the cost report

Every task:

```bash
bin/rails data_teller:check                # in CI and after migrations: reads the tables and columns too
bin/rails "data_teller:schema[support]"    # the JSON schema this role would get
bin/rails "data_teller:catalog[support]"   # the same names, a few lines per dataset, for a person
bin/rails data_teller:isolation            # every row read traced back to its tenant, on this database's rows (TENANTS=12,57,301 CAP=5000)
bin/rails data_teller:costs                # each of those queries' estimated cost next to its real duration, to choose max_query_cost
bin/rails "data_teller:eval[dev]"          # score a model on eval/dev.yml (MODEL=perfect|replay|naive|routed, SAVE=1 to keep the run; naive and routed are paid calls)
```

An invalid configuration keeps the engine off, and by default the app refuses to boot. With `c.on_invalid_config = :disable`, the app boots without the engine and logs the error. The boot itself never reads the database, so it can't block a migration.

`data_teller:isolation` runs one query per declaration (each dimension, segment, metric path, and each filter compared to another tenant's value) as three tenants: by default the first two and the last one. A listable dataset is also listed, with its default columns and with each column it reaches through a path. It traces every row each query reads back to its owner through the `tenant_path` foreign keys, apart from the compiler, and exits 1 if a row belongs to another tenant or a table was read without a tenant filter. It only reads, in a transaction that is always rolled back, so you can point it at an anonymised copy of production; it prints dataset names and ids, never a value. A dataset no tenant read a row of is reported as not proved, not as passed ([ADR 0011](adr/0011-isolation-kit.md)).

`data_teller:costs` runs the same queries, as the same tenants, with `EXPLAIN ANALYZE`, and prints each one's estimated cost next to how long it took, sorted by cost, with a line where your `max_query_cost` falls. Set the threshold below the costs where the durations take off, with a margin: these queries are simple, and real questions combine them. Unlike the kit, it runs every query for real, each under `query_timeout`: point it at a copy of production, not at the primary. It prints costs and durations, never a value.

## Other ways in

For another interface than the palette, call the same path directly:

```ruby
outcome = DataTeller.ask("how many paid orders ship tomorrow?", user: current_user)
outcome.status          # :answered, :clarify, :out_of_scope or :refused
outcome.result&.columns # with outcome.result.rows, when answered

# A list (outcome.result.list?) comes a page at a time: outcome.result.after is the next page's cursor, nil on the last one.
DataTeller.rows(outcome.query, user: current_user, after: outcome.result.after)
```

The palette's "Show more" sends the query and the cursor back to `POST /data_teller/rows`, which checks both again as if the model had written them and never calls the provider.

## Limit the database role

`c.database_role` runs each query as a Postgres role that reads the declared columns only, and `c.row_security` keeps that role to the current tenant's rows. `rake data_teller:grants` prints the SQL, and `rake data_teller:check` verifies it.
