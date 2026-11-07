# ADR 0006 — Evaluation dataset: domain, languages, authorship

Status: accepted (2026-11-07)

Context: M3 measures how well an LLM turns a question into a DataTeller query (T09-T11), and M4 measures whether retrieval improves
on that (T15-T19). The numbers are what sets the article series apart, so the dataset decides whether they mean anything.

## D1 — A realistic domain in the dummy app, not the current two datasets (decided, "A")

The dummy app grows from two datasets to eleven or twelve: an e-commerce SaaS whose tenants are merchants. Orders, line items, products,
customers and shipments stay; refunds, invoices, subscriptions, support tickets, reviews and coupons are added, with fake, deterministic seeds.

- **Why:** with two datasets and four metrics an LLM scores close to 100% without effort, the baseline says nothing, and retrieval has
  nothing to retrieve: the whole catalog fits in the prompt. The domain is built for confusion on purpose: `revenue`, `net_revenue` and
  `refunded_amount`; `invoiced`, `paid` and `outstanding`; several date columns per dataset (`ordered_at`, `paid_at`, `due_on`).
- **Out of scope on purpose:** questions about a margin (no purchase cost in the data), about employees (`users` is not exposed), and unrelated ones.
- **Created, not downloaded.** Public datasets (Olist, Northwind, Pagila, Chinook) have one tenant, names in English or Portuguese, no
  traps under our control, licenses to check, and a download in CI. What the eval scores is the catalog, not the rows.
- **Consequence:** specs that assert the dummy app's exact catalog (`rake data_teller:check` output, `ReaderGrants`, `RowPolicies`) change their
  expected values. The security specs build their own registries and data, and do not depend on it.

Rejected: keeping the dummy app for M3 and growing it for M4 (a flattering baseline, measured again at the moment retrieval must beat it);
a second catalog for the eval only (two domains to maintain).

## D2 — The same questions in English and French (decided, "C")

- English is the main set, quoted in the articles: the series is in English. French is a faithful translation of each question.
- **Why:** end users of a SaaS ask in their own language while the catalog's names are English identifiers; mapping "CA du mois dernier" to
  `revenue` is harder, and more real, than "revenue last month". The score gap between the two languages is a number of its own.
- **Cost:** a full run is twice the calls. Iterations run in English; both languages run at the milestones (baseline, each retrieval variant).
- **Consequence:** synonyms in declarations cover both languages. Whether they should be keyed by language is left for later.

Rejected: French only (the roadmap's first wording: less readable for the series' readers, and no way to tell what the language costs);
English only (loses the realistic case).

## D3 — The author writes the held-out questions

The working set (30 questions) is drafted during development; the held-out set (10) is written by the author,
the way a real user would ask (typos, shortcuts, vague wording), in both languages, and kept out of development until it is measured.

- **Why:** questions written by the same hand that tunes the system give a flattering score.
