# ADR 0007 — Narrowing the catalog before the query: a router call, a naive baseline measured once

Status: accepted (2026-11-08)

Context: the query is generated against a JSON schema built from the role's catalog (ADR 0004 D8). For the dummy app's admin role, measured
on 2026-11-08:

| What would be sent | Size |
|---|---|
| The whole schema (11 datasets) | 32.3 KB |
| The same without the rules the validator checks anyway (`if`/`then`, `not`, `allOf`, bounds, `dependentRequired`) | 24.3 KB |
| One dataset's branch | 2.0 to 3.0 KB |
| The shared parts (clarification, out of scope, definitions) | about 3.5 KB |
| The dataset index (names and synonyms) | 0.6 KB |

The providers' structured outputs, as documented on 2026-11-08 (not yet tried with a real call): OpenAI's strict mode refuses `allOf`,
`not`, `if`/`then` and `dependentRequired`, wants an object at the root, every field required and at most 1000 enum values (884 here);
Anthropic's allows at most 24 optional parameters and 16 unions per request (154 and 25 here); Gemini lists `anyOf`, `$ref` and `enum`
but not `oneOf`, `allOf`, `if`/`then` or `const`. Compressing the schema saves a quarter; sending fewer datasets is what scales,
including for an integrator with fifty datasets.

What is sent is catalog metadata and the user's question, never rows: the problem is size, cost and provider limits, not privacy.

## D1 — Two calls: route, then answer; the whole catalog is measured once (decided, "C")

- **Call 1, the router:** the role's dataset index in, up to a few dataset names out, chosen from an `enum` of the role's datasets.
- **Call 2, the query:** the schema generated from the role's catalog narrowed to those datasets, about 6 KB for one and 11 KB for three.
- **T13 runs the whole catalog once**, for the reference number. No prompt iteration runs on it and it is never shipped: it tells what
  routing costs (a wrong route is a wrong answer) against what a smaller context brings.
- **T14 iterates on the routed path**, the one that ships: each eval run sends several times less.
- **Scored separately**, as every retrieval step (project rule): the router by whether the expected dataset is in its choice, over the
  questions whose expected query is an answer; the end-to-end score does not change.
- **Security:** the router only sees `Catalog.for_user`, never the registry, so it can neither name nor reveal a forbidden dataset. The
  narrowed catalog is a subset of the role's, so narrowing never widens what a user may ask, and the validator still judges the output.
- **Left for T13c:** how many datasets the router may return; whether it answers `out_of_scope` itself, without call 2; whether both
  calls use the same model.

Rejected: the whole catalog on every call and every iteration until M4 (A: every eval run sends 32 KB per question, and Anthropic's
strict mode cannot take it); routing from the start without a naive run (B: no number to tell whether routing helps or loses points).

## D2 — M4 tries to replace the router; the lexical half of hybrid search is trigram (decided, the author's proposal)

- **Three ways to pick the datasets, one metric** (recall@k over datasets): the LLM router (T13c), vectors (T17), and hybrid, vectors plus
  `pg_trgm` trigram similarity merged by reciprocal rank fusion (T18). The router is the simple solution to beat, which is a fairer test
  of retrieval than beating "send everything".
- **Why trigram rather than `tsvector`:** what is indexed is short (a name and a few synonyms), questions come in two languages and,
  in the held-out set, with typos. `tsvector` needs a text search configuration per language and matches stemmed words; trigram is the
  same for every language and tolerates a typo. It is also the pair already chosen for value resolution (ADR 0001 D2), so one technique,
  and `pg_trgm` is already enabled.
- **Open:** measuring `tsvector` as an extra variant at T18 costs no LLM call; to decide there, if trigram disappoints.

Rejected: `tsvector` as the lexical half (above).

## D3 — What the router sees: datasets, synonyms and metric names (decided, "B", 2026-11-08)

Sizes for admin: datasets and synonyms 636 bytes; with metric names 1,003 bytes; with field names too 3,203 bytes.

- **Why metric names:** a dataset's synonyms alone mislead on purpose-built traps: "what did promo codes cost us" matches the synonym of `coupons`, while the answer is
  `orders.discounts`. Only the metric's name tells them apart.
- **Measured, not assumed:** the router has its own score (ADR 0007 D1), so trying another index costs a run.

Rejected: datasets and synonyms only (A: the trap above); field names too (C: three times the size, for a gain nothing shows yet).

## D4 — The router never refuses (decided, "A", 2026-11-08, for now)

- It always returns at least one dataset, its best guess; only the query call can answer `out_of_scope`.
- **Why:** one step decides a refusal, with the detailed catalog in front of it, and a router's mistake does not become a refusal with no second chance.
- **Cost:** an off-topic question makes two calls, a few more seconds before a refusal. A wrong route can still end in a wrongful refusal at the query call; the router's own score shows it.

Rejected for now: an empty list answered directly as `out_of_scope` (B: faster on off-topic questions, but a decision taken from the short index, and two steps deciding the same thing). To revisit if the latency of refusals matters.

## D5 — At most three datasets, ranked (decided, "B", 2026-11-08)

- The router returns one to three datasets, most likely first. The query call gets the schema of those, about 6 KB for one and 11 KB for three (admin).
- **Why more than one:** a question ambiguous between two datasets can still become a clarification, and a first choice that is wrong is not final.
- **Why ranked:** one run gives the router's score at 1, 2 and 3 datasets, so the maximum can be lowered on numbers.
- **One model for both calls** to start with, `c.router_llm` defaulting to `c.llm`: nothing yet says the router needs another.

Rejected: exactly one (a wrong route is always paid, and no clarification between two datasets); at most five (out of eleven datasets, it hardly narrows anything).

## Measured (2026-11-08): the router on the working set

`MODEL=routed`, `gpt-6-luna`, two runs (`spec/dummy/eval/runs/*-dev-routed-*`), against the two naive runs of ADR 0009, all scored with the same accepted answers:

| | Score | Input tokens | From the cache | Output tokens | Median latency | Cost, from list prices |
|---|---|---|---|---|---|---|
| Naive, runs 1 and 2 | 85.1%, 89.2% | 624,666 | 96.8%, 100% | 9,219, 9,102 | 2.6 s, 2.4 s | $0.013, $0.011 |
| Routed, runs 1 and 2 | 83.8%, 82.4% | 159,567, 159,838 | 59.0%, 78.4% | 13,170, 13,012 | 4.0 s, 4.1 s | $0.014, $0.011 |

- **The router's own score:** the right dataset within 1 choice 96.6% and 94.8%, within 2 choices 100% in both runs (58 answers). It returned 1.27 datasets on average.
- **Input is four times smaller, the cost is the same:** the narrowed schemas vary, so less of them comes from the cache, and two calls write more output. On this catalog the router saves no money and adds about 1.5 s.
- **It loses a clarification:** `how_many_active` (`products` or `subscriptions`), right in both naive runs, fails in both routed runs: the router returns one dataset, or not the second one, so the query call cannot ask. Being allowed three datasets (D5) was not enough.
- **Not shown:** that the router helps at all on this catalog. What justifies it is untested so far: provider limits and larger catalogs. Two runs each, with noise of at least 3 answers: the score gap is not settled.

### Five runs each (same day)

Three more runs of each path, alternating, all ten scored with the same accepted answers (out of 74):

| | Right answers, by run | Mean | Standard deviation | Median latency | Cost per run, from list prices |
|---|---|---|---|---|---|
| Naive | 63, 66, 66, 65, 64 | 64.8 (87.6%) | 1.3 | 2.4-3.1 s | $0.011-0.013 |
| Routed | 62, 61, 63, 63, 63 | 62.4 (84.3%) | 0.9 | 4.0-4.2 s | $0.011-0.014 |

- **The gap holds, and it is one question:** 2.4 answers per run, of which 2.0 are `how_many_active` (naive 10/10, routed 0/10). Without it the two paths score alike. `customers_as_member` adds 0.6, a `wrong_reason` of low severity (naive 10/10, routed 7/10).
- **One question is all the working set has on this:** it is the only one expecting a clarification between two datasets, so this says "the router lost that case", not how often such questions occur.
- **Router:** right dataset within 1 choice 94.8-96.6%, within 2 choices 100% in all five runs.

