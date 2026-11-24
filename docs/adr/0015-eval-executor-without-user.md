# ADR 0015 — The eval runs a query from a role and a tenant, not a user

Status: accepted (2026-11-24)

Context: T43. A trial integration showed it. The eval's "to review" flag (ADR 0006 D4) runs a wrong answer and the expected query on the
seeds and compares their rows. Its executor built a user of its own, a struct with `account` and `roles`, and went through `QueryRunner`,
which resolves the tenant and the roles with the host's blocks. The dummy's config reads exactly those two fields; a host's reads its own
user model (`user.organization`, `user.profile`...). There every query came back refused, so `same_result` was always false: a wrong answer
returning the right rows was never flagged. The score itself was right.

## D1 — From the question's role and the set's tenant, as the isolation kit runs its queries (decided, "C")

The executor takes the role's catalog (`Catalog.for(role)`), validates the query with `QueryValidator`, and compiles and runs it inside
`ReadOnlyExecution`, with the database role and the row security of the config. No user, no resolver.

- **Why:** the eval already knows what the resolvers would give, the tenant by name and the role per question. The isolation kit and the
  cost report (ADR 0011, ADR 0013 D4) run their queries this way already, and have run on a host app. Nothing for the integrator to write.
- **Same guarantees:** read-only and rolled back, under `query_timeout`, as the configured database role, row security on when it is.
  Left out: `max_query_cost`, which refuses before running; the eval compares rows on seeds, a refusal there would only hide a flag.
- **The tenant resolver is not tested by it.** It never was in a way that mattered: the struct matched the dummy's resolver by construction.

Rejected: a setting `c.eval_user { |tenant, role| ... }` that builds a user for the full `QueryRunner` (A: one more setting every
integrator writes before the flag works, for a need the gem covers elsewhere without one); a `user:` key in the question set naming a real
user (B: needs a user per role in the seeded database, and ties the file to ids).

## Consequences

- `Evaluation::Executor` no longer calls `QueryRunner`; it returns nil for anything but an answer the role's catalog accepts and the
  compiler runs.
- A spec runs `same_result` under a config whose resolvers read fields the eval cannot build.
