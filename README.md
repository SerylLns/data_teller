# DataTeller

A mountable Rails engine for multi-tenant apps: your users ask questions about their own data in plain language.

**The LLM never writes SQL.** It fills in a structured query, which is validated against what you declared, then compiled
to ActiveRecord with the tenant filter added by the compiler.

> **Status: early work in progress, not for production.**
> It answers questions through a minimal palette, with OpenAI only. There is no per-user limit yet, so anyone with access can spend your provider budget. It is not on RubyGems.

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

That is the design. Retrieval and the explanation are not built yet: today the role's whole catalog goes in the prompt (above 12 datasets, a router narrows it first), and the answer is a table with the dataset, metric and period it was read from.

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
| Postgres row-level security on the tenant, on top of the compiler's filter | Done |
| Minimum group size, complexity budget, security test kit | Next |
| Evaluation suite, `rake data_teller:eval` | Done |
| LLM client (OpenAI), `DataTeller.ask`, a router for large catalogs | Done |
| Minimal palette and endpoint, **not for production yet: no per-user limit** | Done |
| Prompt tuning, retrieval (RAG), explanations, production UI | Not started |

First measures, on fake data, with `gpt-6-luna` and a first prompt nobody has tuned yet:

| Questions, each asked in two languages | Answers right | Runs |
|---|---|---|
| Working set, 37 questions | 87.6% on average | 5 |
| Separate set, the author's 10 questions | 70.0% (14/20) | 1 |

- **The 87.6%** counts answers accepted after a review of the first run, which took that run from 79.7% to 85.1% ([ADR 0007](docs/adr/0007-catalog-narrowing.md), [ADR 0009](docs/adr/0009-baseline.md)).
- **The 70.0%** comes from one run, where one answer is worth 5 points, so the gap between the two numbers is a hint. These questions are never used for tuning, but they were seen during development, so this is not presented as an independent measure ([ADR 0006](docs/adr/0006-evaluation-dataset.md)).

Both say little until retrieval and tuning have something to compare to. The full plan is in [docs/ROADMAP.md](docs/ROADMAP.md).

Known gaps today:

- A filter on a name the user wrote ("orders from Alice") is refused: lookups are not implemented yet.
- Each question stands alone: "and in June?" after a first question does not work.

## Try it in your app

You need Ruby 3.2 or later, Rails 7.2.2.2 or later, and PostgreSQL. **PostgreSQL only:** the compiler uses `date_trunc` and `AT TIME ZONE`.

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
  # Who is asking. The endpoint runs none of your filters, so it reads your authentication here. This line is for Devise.
  c.current_user { |request| request.env["warden"]&.user }
  c.llm = DataTeller::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"), model: "gpt-6-luna")
  c.expose Order, Customer
end
```

Without `c.current_user`, nobody has access. Without `c.llm`, questions are refused, and declarations and checks still work.

Optional: `time_zone { |account| account.time_zone }` in `c.tenant` sets what "today" means for a tenant, and `c.locale { |user| user.locale }` sets the language of the palette (English and French are included).

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
bin/rails "data_teller:catalog[support]"   # the same names, a few lines per dataset, for a person
bin/rails "data_teller:eval[dev]"          # score a model on eval/dev.yml (MODEL=perfect|replay|naive|routed, SAVE=1 to keep the run; naive and routed are paid calls)
```

An invalid configuration keeps the engine off, and by default the app refuses to boot. With `c.on_invalid_config = :disable`, the app
boots without the engine and logs the error. The boot itself never reads the database, so it can't block a migration.

**4. Mount the engine and add the palette**

```ruby
# config/routes.rb
mount DataTeller::Engine => "/data_teller"
```

```erb
<%# in your layout %>
<%= data_teller_palette %>
```

Ctrl/Cmd+K opens it. It renders nothing for someone the endpoint would refuse. **Each question is a paid call to OpenAI.**

For another interface, call the same path directly:

```ruby
outcome = DataTeller.ask("how many paid orders ship tomorrow?", user: current_user)
outcome.status          # :answered, :clarify, :out_of_scope or :refused
outcome.result&.columns # with outcome.result.rows, when answered
```

**5. Recommended: limit the database role**

`c.database_role` runs each query as a Postgres role that reads the declared columns only, and `c.row_security` keeps that role to the current tenant's rows. `rake data_teller:grants` prints the SQL, and `rake data_teller:check` verifies it.

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
| With `c.row_security`, that role sees its tenant's rows only, even if the compiler's filter were gone | Enforced by the database, opt-in; checked by `rake data_teller:check` |
| Minimum group size | Planned |
| No row is sent to the LLM provider | Enforced by construction: what is sent is the question, the date and the role's declarations |
| No sentence shown to an end user comes from the LLM | Enforced: messages come from translations, and clarification options are names the validator checked |

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

To try the palette, with a fake sign-in that picks a seeded user. Each question is a paid call to OpenAI:

```bash
cd spec/dummy
OPENAI_API_KEY=... bin/rails server   # then open http://localhost:3000, sign in, and press Ctrl/Cmd+K
```

The design decisions, with the options that were rejected, are in [docs/adr](docs/adr).

## License

[MIT](MIT-LICENSE)
