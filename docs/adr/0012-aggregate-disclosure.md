# ADR 0012 — Aggregate disclosure: a minimum group size

Status: accepted (2026-11-13)

Context: T36. DataTeller only ever returns aggregates, but an aggregate over a few rows describes those rows: "average salary per department"
with a department of one is that person's salary. ADR 0003 settled the frame: a declarative `min_group_size` suppresses small groups, and it does
not stop differencing (two queries one row apart), which is stated openly. What it protects is a role that may see aggregates but not individuals.
A shop admin counting their own orders is not that case, so the question is where it applies, not only how.

## D1 — What a group's size counts: the dataset's rows, or a declared unit one step away (decided, "C")

By default a group's size is the number of distinct rows of the dataset in it, `COUNT(DISTINCT orders.id)`, computed in the same query as the
answer. A dataset can name its unit instead, a direct `belongs_to`: `of: :customer` counts `COUNT(DISTINCT orders.customer_id)`.

- **Why:** twelve orders from one customer pass a threshold of five rows and still describe one person; the unit is what makes it count people.
  Limited to a direct `belongs_to` because its key is a column of the dataset's own table: counting it adds no join, so no new table that would
  need its own tenant filter.
- **Limits:** a unit two steps away (`line_items` counted by `order.customer`) is not possible yet; it waits for a real case. A distinct count
  is not cheap, see D3: the compiler writes `COUNT(*)` where it gives the same number, the dataset's own rows when every join is a `belongs_to`
  on the parent's primary key, and `COUNT(DISTINCT)` only for a joined dataset, an `of:` unit or a metric path that repeats rows.

Rejected: rows only (A: protects rows, not people, and an equality filter on a customer narrows any total to one person); any declared path as
the unit (B: a unit two steps away adds a join, a table the compiler must filter for the tenant, for a case nobody has yet).

## D2 — Declared on the dataset, for every role but the ones named (decided, "B")

```ruby
min_group_size 5, of: :customer, except: %i[admin]
```

No global default: a dataset is protected only if it declares it. Every role that reads it is then held to the threshold, except the roles named.

- **Why:** only the integrator knows which datasets describe people (`customers`, `support_tickets`, `reviews` do; `products`, `coupons` do not).
  A global default would hide "3 orders today" on every table, and the false alarms would get it switched off. The exemption is what makes the
  rule usable: an admin asking "how much did Alice spend?" asks a normal question, they can open her page in the app anyway. Naming the exempt
  roles rather than the protected ones fails closed: a role added later is protected until someone decides otherwise.
- **Boot checks:** the threshold is a positive integer; `of:` is a direct, non-polymorphic `belongs_to` of the dataset's model, whose key is
  not read without its type (ADR 0004); each role in `except:` is one of the dataset's `roles`. A role that cannot read the dataset has nothing
  to be exempt from, so it is a typo, and a typo there would silently remove the protection from the role meant to be protected.

Rejected: on the dataset for every role, no exemption (A: the integrator has to choose between protecting an analyst and blocking an admin, and
switches it off); a global default with a per-dataset override (C: see above); a threshold per metric (the person is the same whatever the
metric); a list of protected roles, `only:` (forgets the next role).

## D3 — A small group is left out, and the answer says how many were (decided, "A")

A group under the threshold is removed in SQL, with a `HAVING` on its size, and the result carries the number of groups removed (`suppressed`).
The explanation (T28) says it from a template: "3 groups of fewer than 5 customers are not shown".

- **Why:** it is the only option that shows neither the group's label nor its value. The label is data too: with `group_by customer.name` it is
  the list of customers, and "there is a customer in Lyon" is already something. Removing in SQL keeps the top N honest: the 20 groups shown are
  20 groups that may be shown, not 20 minus the ones removed afterwards.
- **What it still tells:** how many groups are small, never which ones.
- **Cost, measured at implementation (2026-11-14).** Counting the removed groups is a second query, the same one with the `HAVING` reversed,
  so a protected answer runs the grouping twice. Synthetic data on local Postgres, one tenant with 50,000 customers in 2,000 cities and 500,000
  orders, threshold 20, 50 groups shown, both queries together:

  | Query | Exempt role | Protected role | `HAVING` |
  |---|---|---|---|
  | `customers` by `city` | 24 ms | 42 ms | `COUNT(*)` |
  | `orders` by `customer.city`, `customers` protected | 143 ms | 3,547 ms | `COUNT(DISTINCT customers.id)` |

  A distinct count stops Postgres from aggregating by hash or in parallel: it sorts every joined row. `COUNT(*)` keeps the plain plan, hence
  the rule in D1. What is left is the joined case and `of:`, about 1.8 s per query here, against a default `query_timeout` of 5 s; a tenant
  with a few million rows in a joined query reaches `query_timeout`. One pass instead of two (the sizes in a sub-query, the removed groups
  counted by a window) would halve it; it waits for a real integration that hits the timeout. Rejected: counting distinct pairs in a sub-query
  first (245 ms in a first measure), because an average, a min or a max cannot be rebuilt from the pairs' sub-totals.

Rejected: kept with a masked value, `< 5` (B: shows the labels of groups under the threshold); merged into "Other" (C: an average, a min or a max
cannot be rebuilt from the groups', so a second query, and "Other" can be under the threshold itself).

## D4 — Every aggregate shown is counted on every protected dataset it reads (decided)

- **Joined datasets (a).** The threshold of each dataset the query touches applies, each counted by its own unit: `orders` grouped by
  `customer.city`, with a threshold on `customers`, counts `COUNT(DISTINCT customers.id)` per city. A touched dataset is already joined, so this
  adds no join; metric paths are covered the same way. A role escapes a threshold only if every dataset that declares one exempts it.
  Rejected: the threshold of the queried dataset only (one city, one customer: that customer's spending).
- **A single value under the threshold (b)** is refused with a new engine reason, `group_too_small`, shown through a template ("too few
  customers to show this number"). Like `too_many_groups`, the engine finds it after running the query and it stays out of `query_v1.json`:
  the LLM cannot pick it. Rejected: a result with no value (B2: `nil` would reach every place that expects a number, `compare`'s delta, the
  palette, the explanation and the eval; and without `group_by`, a `HAVING` that fails returns no row where a plain aggregate returns 0, so "no
  row" would pass for "0 orders").
- **Zero is under the threshold too.** If 0 were shown and 1 to 4 hidden, "hidden" would mean "at least one": asked about one customer, it
  answers whether she bought. Hiding 0 as well keeps a person's presence protected, not only the amounts. The cost: "0 orders in Lyon this week"
  is refused to a protected role; the exemption is there for roles it gets in the way of. Rejected: showing 0 (Z2: protects amounts, not presence).
- **`compare` (c).** Each period is checked on its own. A single value is refused if either period is under the threshold; a group under it in
  either period is left out entirely, since the change between the two would give the hidden one by subtraction. A group missing from a period
  has a size of 0, so it is left out too.

## D5 — Limits: what the threshold does not cover, documented rather than half-solved (decided)

The threshold stops a protected role from reading a small group directly, a person's presence included. It does not stop someone who sets out
to cross-check answers. Four known gaps, each stated in the README and the series rather than partly closed:

- **The total gives the hidden group away.** "Revenue" minus the sum of "revenue by city" is the one city left out. Hiding a second group when
  exactly one is hidden (secondary suppression) blocks only that case: a row total of a two-way table, or another filter, gives it back. Closing
  the easiest case would read as protection against differencing, which this is not.
- **`min` and `max` return one row's value.** The largest salary among fifty is still someone's salary. Nothing new is needed: metric `roles:`
  already exist, so the advice is to give `min` and `max` on a protected dataset to the exempt roles only.
- **Dominance.** A city of six customers where one makes 95% of the revenue gives that customer's amount, roughly. The usual rule (p%) needs
  each contributor's share in every group, a second aggregation; it waits for a real case.
- **Differencing.** Two queries one person apart ("Lyon" and "Lyon except those born in 1980") give that person's value. No threshold stops it
  (ADR 0003). Rate limits and an audit trail (T32) make it slow and visible, not impossible.

Rejected: secondary suppression and hiding `min`/`max` from protected roles by default (more mechanism for a partial answer, or for what roles
already allow).
