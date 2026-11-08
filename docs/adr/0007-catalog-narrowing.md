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

