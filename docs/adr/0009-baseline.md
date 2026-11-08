# ADR 0009 — The naive baseline: model and prompt

Status: D1 accepted (2026-11-08); D2 open

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

## D2 — The first prompt

Open.
