# ADR 0004 — Declaration DSL

Status: in progress (decisions are taken one at a time)

Context: the developer declares what is exposed (datasets, metrics, dimensions, segments, vocabulary).
Nothing is exposed until it is in a visible, versioned file (ADR 0001, README principle).

## D1 — Syntax and layout: `refine` blocks, one file per dataset, vocabulary in I18n (decided, "A+")

- Syntax: `DataTeller.refine Order do ... end` blocks (segments, metrics, dimensions).
- Layout: global config in `config/data_teller.rb` (tenant, LLM, list of exposed models); one file per dataset in
  `config/data_teller/<dataset>.rb`. A new exposed model shows up as a new file in the diff. These are configuration
  files loaded like initializers (reloaded through `to_prepare` in development, validated at boot), not autoloaded app code.
- Vocabulary (labels, synonyms) lives in I18n files, one per locale (`config/locales/data_teller.<locale>.yml`).
  The DSL holds structure and logic; short inline `synonyms` stay allowed. Long synonym lists are never sent whole to the
  LLM: retrieval selects the relevant ones.
- The install generator (T34) writes one file per model plus the locale files.

Why: keeps the explicit, reviewable exposure; scales to many models without a 600-line initializer; separates logic from
language-dependent vocabulary; consistent with labels already coming from I18n.

Security/performance: files are developer-authored Ruby loaded like initializers (same trust level, no user input);
the registry is built at boot, negligible runtime cost.

Rejected: concern inside each model (touches models, scatters the exposed surface, contradicts the explicit-exposure principle);
a single initializer for everything (unreadable beyond a few models); autoloaded `app/data_teller/` (code-like, harder to review as config).
Possible later: support the autoloaded layout without breaking this one.

## Pending

- D2 how metrics are declared (sum/count/avg, business scopes, derived metrics)
- D3 dimensions and their types (date, enum, lookup, hidden)
- D4 segments (reuse existing scopes by name vs inline definitions)
- D5 roles and permissions in the DSL
- D6 registry object and validation at boot
