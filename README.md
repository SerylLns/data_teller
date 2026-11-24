<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
    <img src="docs/assets/banner-light.svg" width="900" alt="DataTeller: a question goes to an LLM that fills a JSON query; a validator, a compiler that adds the tenant filter, and a read-only Postgres transaction take it from there. The LLM never writes SQL.">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/SerylLns/data_teller/actions/workflows/ci.yml"><img src="https://github.com/SerylLns/data_teller/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/status-experimental-orange" alt="Status: experimental">
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.2-CC342D?logo=ruby&logoColor=white" alt="Ruby 3.2 or later">
  <img src="https://img.shields.io/badge/rails-%3E%3D%207.2-D30001?logo=rubyonrails&logoColor=white" alt="Rails 7.2 or later">
  <img src="https://img.shields.io/badge/PostgreSQL-only-4169E1?logo=postgresql&logoColor=white" alt="PostgreSQL only">
  <a href="MIT-LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  <a href="https://dev.to/seryllns_/building-datateller-0-why-i-dont-let-an-llm-write-sql-2hjl"><img src="https://img.shields.io/badge/the%20build-on%20dev.to-0A0A0A?logo=devdotto&logoColor=white" alt="The build, written up on dev.to"></a>
</p>

<p align="center">
  <a href="#why">Why</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#security-in-one-picture">Security</a> ·
  <a href="#where-it-stands">Where it stands</a> ·
  <a href="#try-it-in-your-app">Try it</a> ·
  <a href="#follow-the-build">Follow the build</a>
</p>

DataTeller is a mountable Rails engine for multi-tenant apps. Your users ask a question in their own words; an LLM turns it into a structured query, which is checked against what you declared, then compiled to ActiveRecord with the tenant filter added by the compiler, on every table.

> [!WARNING]
> **Early work in progress, not for production.** It answers questions through a minimal palette, with OpenAI only. There is no per-user limit yet, so anyone with access can spend your provider budget. It is not on RubyGems.

## Why

Letting a model write SQL makes tenant isolation an instruction in a prompt, and every query a piece of generated code that nobody reviewed. DataTeller takes the opposite approach: the model only picks names from a closed list, and everything that touches the database is our code.

| | Text-to-SQL | DataTeller |
|---|---|---|
| **Who writes the SQL** | The model | The compiler, from your declarations |
| **Tenant isolation** | A line in the prompt, or a check on SQL someone else wrote | A filter the compiler adds to every table it touches, checked before the query runs |
| **What a prompt injection gets** | Whatever SQL the checks miss | A query the user was allowed to ask anyway, or a refusal |
| **What the provider sees** | Depends on the tool: the schema, sometimes sample rows | The question, the date and the names this role may use. Never a row |
| **How you test it** | Read the queries it generated | `rake data_teller:isolation` traces every row read back to its tenant, on your own tables |
| **What it costs you** | Little setup | Declarations to write, and only the question shapes the format allows |

## How it works

The banner above is the whole pipeline, and only one step of it is the model's. Before that step, the role's catalog is narrowed to what the question needs (a router call above 12 datasets); after it, the JSON is validated against the role's permissions, compiled with bound parameters only, and run in a read-only transaction with a time budget. The answer is a table, with the dataset, metric and period it was read from.

Retrieval (RAG) and a written explanation of the answer are the plan, not built yet.

### One question, end to end

**"How many paid orders ship tomorrow?"** The LLM produces this:

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

And this is the SQL it runs on the dummy app (fake data), with comments added:

```sql
SELECT COUNT(*) AS c0 FROM "orders"
WHERE "orders"."status" = $1                                -- the "paid" segment, as you declared it
  AND "orders"."ship_on" >= $2 AND "orders"."ship_on" < $3  -- "tomorrow", in the tenant's time zone
  AND "orders"."account_id" = $4                            -- the tenant filter, added by the compiler
```

Every value is a bound parameter, and every column name comes from your declarations. The LLM can also ask for a clarification or say the question is out of scope, both from closed lists rather than in free text.

> [!NOTE]
> The question itself is sent to the provider as typed: if a user writes a customer's name in it, that name goes too.

## Security in one picture

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/security-layers-dark.svg">
    <img src="docs/assets/security-layers-light.svg" width="900" alt="Five layers between a question and the data: the LLM only fills a JSON query; a validator checks every name against the role; the compiler adds the tenant filter on every table with bound parameters; Postgres runs it read-only within a time budget; an optional database role with row-level security holds even without the compiler's filter.">
  </picture>
</p>

Isolation is tested in `spec/security/` against hostile scopes and values and common table shapes, on real rows across two tenants: that shows the cases tried, not all possible ones. Every rule, its state, and what the rules do not cover: [docs/security.md](docs/security.md).

## Where it stands

Built one decision at a time, each [written down](docs/adr/README.md) with the options rejected. The plan is in [docs/ROADMAP.md](docs/ROADMAP.md).

- ✅ **The core, with no LLM in it.** Query format, declarations checked at boot, validator, compiler, permissions by role, read-only execution, database role and row-level security, minimum group size, lists.
- ✅ **Tools to check it on your own data.** `rake data_teller:check`, the isolation kit, the cost report, the evaluation suite.
- ✅ **A first LLM integration.** OpenAI, `DataTeller.ask`, a router for large catalogs, a minimal palette. **No per-user limit yet.**
- ⬜ **Next.** Prompt tuning, retrieval (RAG), filters on names, labels and a production UI, explanations, rate limits.

| First measures, fake data, `gpt-6-luna`, untuned prompt | Answers right | Runs |
|---|---|---|
| Working set: 37 questions, each in English and French | **87.6%** on average | 5 |
| The author's 10 questions, kept apart | **70.0%** (14/20) | 1 |

One run moves by about three answers, so these mostly give a starting point for tuning and retrieval.

<details>
<summary>How they were measured</summary>

- **The 87.6%** counts answers accepted after a review of the first run, which took that run from 79.7% to 85.1% ([ADR 0007](docs/adr/0007-catalog-narrowing.md), [ADR 0009](docs/adr/0009-baseline.md)).
- **The 70.0%** comes from one run, where one answer is worth 5 points, so the gap between the two numbers is a hint. These questions are never used for tuning, but they were seen during development, so this is not presented as an independent measure ([ADR 0006](docs/adr/0006-evaluation-dataset.md)).

</details>

<details>
<summary>Known gaps</summary>

- A filter on a name the user wrote ("orders from Alice") is refused: lookups come with retrieval.
- Each question stands alone: "and in June?" after a first question does not work.
- The palette shows your declared names as they are (`count`, `ordered_at`) and dates in ISO format: there are no labels yet.
- A path through an optional `belongs_to` is an inner join: a breakdown, or a list column, through that parent leaves out the rows with no parent, while the total keeps them.
- With a soft-deleted parent, a total and its breakdown can disagree. The total keeps a row whose parent is deleted (who owns a row does not depend on a soft-delete), while a `group_by` through that parent leaves it out, since the parent's `default_scope` applies to the join. The same goes for an `always` condition. With `discard`, which has no `default_scope`, discarded rows are counted unless `always` leaves them out.
- A user has one tenant: someone who sees several gets the one the resolver returns.

</details>

## Try it in your app

You need Ruby 3.2 or later, Rails 7.2.2.2 or later, and PostgreSQL. **PostgreSQL only:** the compiler uses `date_trunc` and `AT TIME ZONE`.

### 1. Install it from the repository

```ruby
gem "data_teller", github: "SerylLns/data_teller"
```

```bash
bin/rails generate data_teller:install
```

This writes `config/data_teller.rb`. The tenant is commented out on purpose, so **your app will not boot until you set it**: there is no safe default to guess.

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

### 2. Declare each exposed model, in one file per model

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

Optional, each explained in [docs/configuration.md](docs/configuration.md):

- [`list default:`](docs/configuration.md#lists-answer-show-me-the--with-rows) answers "show me the ..." with rows, a page at a time.
- [`always where:`](docs/configuration.md#leave-out-rows-your-app-always-hides) leaves out rows your app always hides, archived or discarded.
- [`min_group_size`](docs/configuration.md#hide-small-groups-from-some-roles) hides groups smaller than N from some roles, on datasets that describe people.
- [`time_zone` and `c.locale`](docs/configuration.md#time-zone-and-language) set what "today" means and the palette's language.
- [`c.query_timeout` and `c.max_query_cost`](docs/configuration.md#how-heavy-a-question-may-be) bound how heavy a question may be.

### 3. Check it

```bash
bin/rails data_teller:check         # in CI and after migrations: reads the tables and columns too
bin/rails data_teller:isolation     # every row read traced back to its tenant, on this database's rows
bin/rails "data_teller:eval[dev]"   # score a model on your own questions in eval/dev.yml
```

An invalid configuration keeps the engine off, and by default the app refuses to boot. The other tasks (the schema and catalog a role gets, the cost report) are in [docs/configuration.md](docs/configuration.md#checks-the-rake-tasks-the-isolation-kit-and-the-cost-report).

### 4. Mount the engine and add the palette

```ruby
# config/routes.rb
mount DataTeller::Engine => "/data_teller"
```

```erb
<%# in your layout %>
<%= data_teller_palette %>
```

Ctrl/Cmd+K opens it. It renders nothing for someone the endpoint would refuse. **Each question is a paid call to OpenAI.** For another interface, `DataTeller.ask` takes the same path ([other ways in](docs/configuration.md#other-ways-in)).

Recommended: [run the queries as a limited database role](docs/configuration.md#limit-the-database-role), with row-level security.

## Follow the build

I'm writing the build up as a series on dev.to, decisions and measures included: [part 0, why I don't let an LLM write SQL](https://dev.to/seryllns_/building-datateller-0-why-i-dont-let-an-llm-write-sql-2hjl).

Not open to contributions before a first stable version; to run it locally, see [docs/development.md](docs/development.md). Found a security issue? Please don't open a public issue: see [SECURITY.md](SECURITY.md).

## License

[MIT](MIT-LICENSE)
