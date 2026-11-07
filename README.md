# DataTeller

A mountable Rails engine for multi-tenant apps: your users ask questions about their own data in plain language.

**The LLM never writes SQL.** It fills in a structured query, which is validated against what you declared, then compiled
to ActiveRecord with the tenant filter added by the compiler.

> **Status: early work in progress. It does not answer questions yet.**
> A hand-written JSON query runs, but there is no LLM integration and no UI so far. It is not on RubyGems, and it must not be used in production.

## Why not text-to-SQL

Letting a model write SQL makes tenant isolation an instruction in a prompt, and it makes every query a piece of generated code
that nobody reviewed. DataTeller takes the opposite approach:

```text
Question
   |
   v
Retrieve what is relevant in your declarations (RAG)
   |
   |   sent to the LLM: the question, and the names this role can see. Never rows from the database.
   v
LLM fills in a JSON query                     <- untrusted
   |
   v
Validate names, types and permissions         <- our code from here on
   |
   v
Compile to ActiveRecord, tenant filter last
   |
   v
Run read-only, with limits
   |
   v
Result, plus an explanation written without the LLM
```

This is what the LLM produces for "how many paid orders ship tomorrow?":

```json
{
  "version": 1,
  "intent": "answer",
  "dataset": "orders",
  "metric": "count",
  "period": { "dimension": "ship_on", "range": { "relative": "tomorrow" } },
  "filters": [{ "segment": "paid" }]
}
```

It can also ask for a clarification or say the question is out of scope, both from closed lists of reasons rather than in free text.

The question itself is sent to the provider as typed: if a user writes a customer's name in it, that name goes too.

## Where it stands

| Piece | State |
|---|---|
| Query format (JSON Schema) | Done |
| Declaration DSL, tenant declaration | Done |
| Boot validation, `rake data_teller:check` | Done |
| Per-role catalog, schema generated for the LLM | Done |
| Query validator | Done |
| Compiler, tenant filter on every table, running a hand-written JSON query | Done |
| Execution guards: read-only transaction, statement timeout, row and group caps | Done |
| Period comparison (`compare`) | Done |
| Permissions by role, on every use of a name | Done |
| Read-only database role, limited to the declared columns | Done |
| Minimum group size, complexity budget, security test kit | Next |
| Evaluation suite, LLM client | Not started |
| Retrieval (RAG), UI, explanations, security test kit | Not started |

No accuracy or retrieval number exists yet, because nothing has been measured. The full plan is in [docs/ROADMAP.md](docs/ROADMAP.md).

## What you can try today

You can declare what is exposed, have it validated, and see the schema a role would get.

**1. Install it from the repository**

```ruby
gem "data_teller", github: "SerylLns/data_teller"
```

```bash
bin/rails generate data_teller:install
```

This writes `config/data_teller.rb`. The tenant is commented out on purpose, so **your app will not boot until you set it**:
there is no safe default to guess.

```ruby
DataTeller.configure do |c|
  c.tenant do
    model Account
    resolve { |user| user.account }
  end
  c.roles { |user| user.roles }
  c.expose Order, Customer
end
```

**2. Declare each exposed model, in one file per model**

```ruby
# config/data_teller/orders.rb
DataTeller.refine Order do
  roles :admin, :support
  tenant_path :account

  metric :revenue, sum: :total_cents, format: :money, roles: :admin
  metric :avg_basket, ratio: %i[revenue count]

  dimension :ordered_at, time: true
  dimension :ship_on
  dimension :status

  segment :paid, where: { status: :paid }
end
```

A column that isn't declared can't be queried. A `count` metric exists on every dataset without being declared.

**3. Check it**

```bash
bin/rails data_teller:check                # in CI and after migrations: reads the tables and columns too
bin/rails "data_teller:schema[support]"    # the JSON schema this role would get
```

An invalid configuration keeps the engine off, and by default the app refuses to boot. With `c.on_invalid_config = :disable`, the app
boots without the engine and logs the error. The boot itself never reads the database, so it can't block a migration.

## Security model

These are the rules the project is built around. **Only what is marked as enforced exists today.**

| Rule | State |
|---|---|
| Nothing is exposed unless it is declared | Enforced |
| Every dataset declares a path to the tenant, checked at boot | Enforced |
| The schema generated for the LLM only contains names the role can see | Enforced, but not a security boundary: the query validator re-checks everything |
| A resolver returning anything but the tenant model means no tenant | Enforced |
| A forbidden name and an unknown one get the same refusal | Enforced by the query validator |
| A permission applies to every use of a name: reading, filtering, grouping, ordering, and through paths, ratios and segments | Enforced |
| Values are bound parameters; column names come from declarations, never from the query | Enforced |
| The tenant filter is applied last, on every table touched, and checked before running | Enforced |
| A `scope:` used as a segment, and a `default_scope`, can only hold comparisons of the model's columns to plain values | Enforced: raw SQL, sub-queries, `from`, `joins` and the like are refused |
| Queries run in a read-only transaction with a timeout, enforced by the database | Enforced |
| With `c.database_role`, queries run as a Postgres role that reads the declared columns only | Enforced by the database, opt-in; checked by `rake data_teller:check` |
| Minimum group size | Planned |
| No row is sent to the LLM provider | Planned, by construction |

Isolation is tested in `spec/security/` against hostile scopes and values, on real rows across two tenants. That shows the cases tried, not all possible ones.
Some limits are known and won't go away. The boot checks that a `tenant_path` reaches the right model, not that it means the right
thing, so that line has to be reviewed. The check for sensitive column names is a lint, not a guarantee.

## Development

You need Ruby 3.2 or later and PostgreSQL with the `vector`, `pg_trgm` and `unaccent` extensions. `docker compose up -d` starts a suitable
database on port 5433; if you use it, set `PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres PGPASSWORD=postgres`.

```bash
bundle install
RAILS_ENV=test bundle exec rails db:create db:schema:load
bundle exec rspec
bin/rubocop
```

`spec/dummy` is a small shop app (accounts, customers, products, orders) with **fake, deterministic seeds**, for development and tests only.
To run a JSON query on them and see the SQL:

```bash
cd spec/dummy
bundle exec rails db:create db:migrate db:seed
bundle exec rake "try[Acme,admin]" QUERY='{"version":1,"intent":"answer","dataset":"orders","metric":"revenue"}'   # admin, support or member
```

The design decisions, with the options that were rejected, are in [docs/adr](docs/adr).

## License

[MIT](MIT-LICENSE)
