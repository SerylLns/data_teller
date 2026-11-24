# Security policy

DataTeller exists to let people query data they must not see past. A way around that is the bug I most want to hear about.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately, either way:

- through GitHub: the **Security** tab of this repository, then **Report a vulnerability**;
- by email to contact@seryl.dev.

Include what you can of: the declarations involved (a `DataTeller.refine` block is enough), the JSON query or the question, what you expected and what came back, and the output of `rake data_teller:isolation` if it shows the problem. Leave real data out: fake rows that reproduce it are better.

This is a one-person project, not a company with an on-call rotation. I'll acknowledge a report as soon as I can, keep you posted while I work on it, and publish the fix before anything about the issue. Credit goes to you in the fix's notes unless you'd rather not.

## What counts

- A user reads, filters or groups by rows of another tenant.
- A role reads a dataset, metric, dimension or segment it was not given, or learns that one exists through a refusal.
- Any way for the model's output, or the question, to change the SQL beyond the names and values the format allows.
- A row of the database sent to the LLM provider.
- A sentence written by the model shown to an end user.
- A write to the database, or a query that escapes the time budget, from a question.
- A small group shown to a role held to a `min_group_size`, by a single query.

## What doesn't

- **The limits documented in the [security model](docs/security.md#what-these-rules-do-not-cover)** and in [ADR 0012](docs/adr/0012-aggregate-disclosure.md) D5: totals giving a hidden group away, `min` and `max`, dominance, differencing across several questions. They are known and written down; a new way to exploit them is still welcome, as a regular issue.
- **A prompt injection that yields a query the user was allowed to ask anyway.** That is the design working: the worst a model's output can be is a valid question within the user's permissions.
- **A `tenant_path` that reaches the right model through the wrong meaning.** The boot checks where a path ends, not what it means; that line is the integrator's to review.
- **No per-user rate limit.** Known, and on the roadmap: the project is not meant for production yet.

## Supported versions

None is released. Fixes land on `main`.
