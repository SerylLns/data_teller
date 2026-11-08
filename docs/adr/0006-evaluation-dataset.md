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
- **Amended the same day:** the author's first ten were seen during development before being stored. Seen means no longer held out: seven
  joined the working set (now 37; the other three repeated working questions), and the author writes ten new ones, from a user's point
  of view before looking at the catalog, checked locally with the spec and kept away from development.
- **Amended again (2026-11-08):** the author's ten new ones had three invalid expected queries, and fixing them meant reading the file during development.
  That review found two more mistakes the spec could not see (a comparison with no `compare`, a French question asking something else than the English one). So the
  set has been seen too. It stays separate, in `held_out.yml`, written by the author, never used for tuning, run only at milestones and still reported by id and
  number, so that a run does not show where to tune. It can reveal overfitting to the working set; it is **not presented as an independent measure**. That role
  goes to a trial integration in a real app, by the author, with nothing prepared for it during development.

## D4 — The score: right or wrong per question, after normalization (decided "A", 2026-11-07)

- **The headline number is the share of questions answered right.** A question counts when the model's query, normalized, equals the
  expected query or one of its `also_accepted`. A query with the wrong metric gives the user a wrong number: partial credit would hide it.
- **Normalization, each rule listed and tested** (`DataTeller::Evaluation::Normalizer`): filters and groups in any order; `in` with one
  value is `eq`; a period is compared by the dates it resolves to on the dataset's day (`last_month` is `between 2026-10-01 and 2026-10-31`);
  an `order_by` the compiler would apply anyway (by the metric, descending, on a high-cardinality group), or one that only changes the
  order of rows nothing cuts, is dropped; clarification options as a set. `version` is ignored.
- **Diagnostics, never in the headline:** which fields differ from the expected query; the error class and its severity; and a
  "to review" flag when a wrong query returns the same rows as an expected one on the seeds, which is usually a missing `also_accepted`.

  | Expected | Model | Class | Severity |
  |---|---|---|---|
  | answer | another answer | `wrong_answer` | high |
  | out_of_scope | an answer | `answered_out_of_scope` | high |
  | answer | clarify | `unnecessary_clarification` | medium (ADR 0001 D5) |
  | clarify | an answer | `missed_clarification` | medium |
  | out_of_scope | clarify | `clarified_out_of_scope` | medium |
  | clarify | another clarification | `wrong_clarification` | low |
  | answer or clarify | out_of_scope | `wrongful_refusal` | low |
  | out_of_scope | another reason | `wrong_reason` | low |
  | anything | unreadable, or refused by the validator | `invalid_output` | low: the user gets a refusal |

- **Broken down by language and by tag**, the gap between English and French being D2's number.
- **The held-out set is reported by id and by number only:** no question text and no model output, so a report cannot feed back into tuning.

Rejected: an average of the fields (ten queries each a little wrong can score 85% while no answer is right); comparing results only
(two different metrics can return the same number on small data, and a clarification does not run).
