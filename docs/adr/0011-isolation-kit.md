# ADR 0011 — The isolation kit: proving tenant isolation on the integrator's own tables

Status: accepted (2026-11-10)

Context: T31a. `spec/security/` proves the compiler on the dummy app: our models, our declarations, two tenants we built, a sentinel value we chose.
It proves nothing about a host app. A wrong `tenant_path`, a scope that widens, a default_scope or a table shape we never met (STI, soft-delete,
nullable keys: `spec/security/table_shapes_spec.rb`) can return another tenant's rows with a compiler that is right. `rake data_teller:check` judges
the declarations without reading rows; the kit reads rows.

## D1 — The oracle: who owns each row read, found by another way (decided, "A")

For each query, the kit runs the compiled relation without its aggregate and collects the primary key of **every table it touches**: the dataset's
own table and each joined one (possible because the compiler refuses to join a table twice). Then, for each row, it follows the `tenant_path` of that
table's own dataset through the Ruby associations, preloaded by batches, and checks that it ends at the tenant who asked.

- **Why:** the check is independent of what it checks. The compiler filters with SQL sub-queries built by `TenantScope`; the kit walks associations
  loaded by ActiveRecord. A bug has to be in both to go unseen. It judges each row, not a total that could balance out, and it writes nothing.
- **Limits:** it needs an internal way to get the relation of a plan without the aggregate. Above a row cap per query, the report says the query was
  checked in part, never that it passed.

Rejected: comparing each answer with and without the other tenants' rows (B: deleting a tenant's rows in a host app, even in a rolled-back
transaction, runs into foreign keys, callbacks and `dependent: :restrict`; and it only sees a leak if the other tenant's rows change the result.
A possible addition later, for aggregates); answers written by the integrator (C: work for them, covers only what they thought of, breaks with the seeds).

## D2 — A Ruby core and its ways in, the rake task first (decided, "C in two steps")

`DataTeller::IsolationCheck` returns a report. v0 ships it with `rake data_teller:isolation`, which prints the report and exits non-zero on a leak.
RSpec shared examples and a Minitest assertion come later, as thin layers over the same core.

- **Why:** the kit only reads, so it can run where the data has its real shape: a development database, an anonymised copy of production, a seeded
  CI database. A test database built by factories rarely has that. It works the same for RSpec and Minitest apps.
- **Limit:** a rake task is not in the test suite; it has to be run on purpose, or added to CI.
- **Roadmap:** T31a said "shared examples"; they move after v0.

Rejected: shared examples only (A: leaves out Minitest, Rails' default, and the test database rarely holds realistic rows); the three ways in at once
(C in one step: three surfaces to keep in step before the core has been used once).

## D3 — Every declared role at once; three tenants by default, any by choice (decided, "C")

- **Roles:** the union of every declared role, so one catalog holds everything reachable. The tenant filter does not depend on the role: roles narrow
  fields, not rows. What each role may see is `spec/security/permissions_matrix_spec.rb`'s business.
- **Tenants:** by default the first two by primary key, often the oldest and fullest, and the last one, often new and nearly empty. A tenant with no
  rows is a good probe: anything it reads is a leak. `TENANTS=12,57,301` replaces them.
- **No green it did not earn:** for each dataset the report gives the number of rows each tenant read. A dataset no chosen tenant read a row of is
  reported as not proved, a warning, not a pass.
- **What the report shows:** dataset names, query shapes and primary keys. Never a value: it runs on copies of production, and its output ends up in
  CI logs.

Rejected: fixed automatic tenants with no override (A: nothing guarantees they touch every table); tenants always given by hand (B: the integrator
has to know which accounts are representative, and a CI has to know ids).

## D4 — One query per declaration, every one, always the same (decided, "A")

For each dataset of the catalog: the plain query; each dimension in `group_by`; each segment as a filter; each metric with a path; each filterable
dimension compared to a value read from **another** tenant's rows, the "another customer's id" attack.

- **Why:** on the integrator's side, the unit of risk is a declaration: a path, a segment, a `scope:`, a default_scope. Each one is proved on its own,
  the same way on every run. The number of queries grows with the catalog, not with its square.
- **Limit:** two declarations that only leak together are not tried. Such an interaction would come from the compiler, which the matrix in
  `spec/security/tenant_isolation_matrix_spec.rb` covers on the dummy.

Rejected for v0: every pair of declarations (B: thousands of queries on a large catalog, for interactions the compiler's own specs cover);
reproducible fuzzing (C: coverage never guaranteed, a report that changes with the seed). Fuzzing stays a later option (`FUZZ=500`), to find what
nobody thought of.

## D5 — How the kit reads the rows: the plan's list, checked against its SQL (decided, "C")

A compiled `Plan` gives the kit, and nothing else, three things: the datasets it touches (`touched`, the list the compiler builds its tenant
filters from), `row_keys`, the same relation with no aggregate, no `GROUP BY` and no `ORDER BY` that plucks the primary key of each of those
datasets, and `tables_read`, the tables in its `FROM` and its `JOIN`s, read from the relation's Arel. A `ComparedPlan` gives its two plans.

- **Why:** the kit needs the dataset, not only the table, to follow the right `tenant_path`: one table can serve several classes (STI, a
  soft-delete `default_scope` on a second class). Only the compiler knows which. But the compiler filters exactly the tables of that same list,
  so a table missing from it would have no filter and no check. The kit therefore compares the list with the tables the SQL really reads:
  a table read and not listed is a failure, even with no row leaked.
- **Limits:** a dataset whose model has no single primary key cannot be checked row by row; the report says it is not proved. `row_keys`
  reads at most `cap + 1` rows, the extra one telling the kit it checked in part. Neither method is reachable from a question: no IR field leads
  to them.

Rejected: the plan's list alone (A: a table the compiler forgot is skipped by the kit as well); tables read from the SQL alone (B: from a table
name, the dataset is a guess as soon as two classes share a table).
