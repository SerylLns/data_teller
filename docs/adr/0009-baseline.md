# ADR 0009 — The naive baseline: model and prompt

Status: accepted (2026-11-08)

Context: T13 runs the whole catalog once for the reference number (ADR 0007 D1), on OpenAI (ADR 0008 D2). The model is an integrator's
setting (`c.llm`); what is decided here is the model of the eval and of the series.

## D1 — A small model: `gpt-6-luna` (decided, "A")

OpenAI's prices on 2026-11-08, per million tokens (input / output / cached input):

| Model | Price | One eval run, estimated |
|---|---|---|
| `gpt-6-luna` | $0.10 / $0.50 / $0.01 | about $0.05-0.07 |
| `gpt-5.4-mini-2026-03-17` | $0.75 / $4.50 / $0.075 | about $0.4-0.6 |
| `gpt-6.1-terra` | $1.00 / $5.00 / $0.05 | about $0.5-0.7 |
| `gpt-6.1-sol` | $2.00 / $10.00 / $0.10 | about $1-1.4 |

Estimates: 74 calls of about 6,600 input tokens (the one real call of T12) and 100 to 500 output tokens; other models may tokenize differently.

- **Why:** the task is narrow (a strict schema, the validator behind it), and a feature used by a SaaS's end users is paid per question, so
  the small model is what an integrator would pick. Whether it is enough is what the baseline measures.
- **Not pinned:** the key lists no dated snapshot of the 6.x models, so the name may point to another model later. Each saved run records
  the model name the API answers with, next to the date, so that a change shows in the runs instead of skewing T14's comparisons.
- **Costs are measured, not estimated, from the first run:** input, cached and output tokens are recorded.
- If the score is very low, one comparison run on a larger model costs under a dollar.

Rejected: `gpt-5.4-mini` (pinned and already tried, but 7.5 times the price); a larger model for the baseline (not what integrators would
ship); two models at once (C: the author's call, a small model is enough to start).

## D2 — The rules and the catalog as compact text, next to the schema (decided, "B")

- **The system message:** the task's rules (answer, ask to clarify, or say out of scope), today's date in the tenant's time zone, and the
  role's catalog as `CatalogSummary` writes it: datasets with their synonyms, metrics with their aggregation, dates with the default one,
  fields with their values and uses. About 8.4 KB more for admin. The schema still constrains the output.
- **Why:** the schema holds names only. Without the synonyms a French question starts with a handicap of our own making, and the baseline
  would measure a strawman. "Naive" means everything the gem knows about the catalog, in the prompt, with no selection.
- **The question goes in the user message**, apart from the instructions. An injection can only produce a query the user could have asked:
  bounded by the role's catalog, filtered by tenant by the compiler.
- **No tenant data:** enum values come from the declarations, not the database; lookup values are not listed.

Rejected: the schema alone (A: no synonyms, a strawman baseline); hand-written examples now (C: they would compete with dynamic few-shot,
T20, and blur what the catalog brings; a measured iteration for T14 instead).

## The baseline (measured, 2026-11-08)

`rake "data_teller:eval[dev]" MODEL=naive`, prompt `dfaad1b02cf2`, `gpt-6-luna`, the 37 working questions in both languages, one run:
`spec/dummy/eval/runs/20261108-125141-dev-naive-gpt-6-luna.json`. The held-out set does not exist yet, so this is not a held-out number.

- **Score: 79.7% (59/74);** English 78.4% (29/37), French 81.1% (30/37). One question is 2.7 points of a language's score and run-to-run
  variation is not measured: the gap between the languages means nothing yet.
- **Errors:** 7 `wrong_answer` and 2 `answered_out_of_scope` (high), 2 `missed_clarification` (medium), 2 `wrong_reason` and 2 `wrongful_refusal` (low).
  4 of the `wrong_answer` carry the "same rows" flag. No expected query was changed after the run: 79.7% stands as the number of this file.
- **Tokens:** 624,666 in, of which 604,885 from OpenAI's cache (96.8%), 9,219 out; 8,441 input tokens per call on average; median latency 2,554 ms.
- **Cost, computed from the list prices, not read from an invoice:** about $0.013 for the run, against the $0.05-0.07 estimated in D1, which ignored the cache.
- **What it changes:** ADR 0007 D1 counted on cheaper eval runs to justify iterating on the routed path. On this catalog, at this price, cost is not
  the argument. Routing rests on the provider limits and on larger catalogs.

### Reviewed, then run again (same day)

- **Three `also_accepted` added**, the "same rows" answers right by their meaning (`promo_cost_this_year`, `urgent_open_tickets`, `new_customers_by_month`). The first
  run scored again without a call: **85.1% (63/74)**, en 83.8%, fr 86.5%. Both numbers are kept: 79.7% before the review, 85.1% after it.
- **Second run, nothing changed:** **89.2% (66/74)**, en 89.2%, fr 89.2%, `20261108-125910-dev-naive-gpt-6-luna.json`. 10 of the 74 outputs differ from the first run, and
  the score moves by 3 answers, or 4 points. Two runs show that the noise exists, not how large it is: T14 cannot read a gain of a few answers from one run per change.
- **Same answer, different class:** `other_merchant/fr` was an `answered_out_of_scope`, now an `invalid_output` (`contains` on a lookup, refused by the validator).
- Cost of the second run from the list prices: about $0.011, with 99.96% of the input tokens from the cache.

### The author's ten questions (same day)

Reference run on `held_out.yml`, before any prompt change, same prompt and model: **70.0% (14/20)**, en 60.0% (6/10), fr 80.0% (8/10), `20261108-131357-held_out-naive-gpt-6-luna.json`.
One run, and one answer is 5 points here: the gap with the working set (85.1% and 89.2%) is a hint, not a measure. These questions were seen during development (ADR 0006 D3).
About $0.003 from the list prices; median latency 3,669 ms.

