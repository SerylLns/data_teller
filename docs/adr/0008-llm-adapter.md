# ADR 0008 — The LLM adapter

Status: accepted (2026-11-08)

Context: T12 plugs a provider in. The pipeline makes two calls per question (ADR 0007 D1, router then query), providers accept different
subsets of JSON Schema (ADR 0007, context), and integrators will want providers the gem does not ship (Bedrock, a local model). The
project rule stands: no orchestration framework, raw HTTP.

## D1 — A low-level adapter: one call, one schema translation (decided, "A")

```ruby
DataTeller.configure do |c|
  c.llm = DataTeller::Providers::SomeProvider.new(api_key: ENV["..."], model: "...")
  c.router_llm = ...  # optional, defaults to c.llm
end

# An adapter answers two methods:
complete(system:, user:, schema:)  # => a response: output, input_tokens, output_tokens, latency_ms
provider_schema(schema)            # a pure function: DataTeller's schema -> the subset this provider accepts
```

- **The gem owns the prompts and the chain** (router, then query). The adapter owns the HTTP call, authentication, the schema translation
  and reading the provider's answer. Prompts stay under the eval: one prompt for every provider, changed only with an eval run.
- **The translation may lose rules** (`if`/`then`, `not`, bounds...). The validator judges every output anyway (T22), so a lost rule
  becomes an `invalid_output` and a refusal, never a wider query. The schema was never a security boundary (ADR 0004 D8).
- **Tested without network:** `provider_schema` is pure, so a spec can check that the translated schema still accepts every expected
  query of the working set; a translation that forbids a right answer would score the model wrong.
- **A custom adapter is one class with two methods.** The shipped ones share one HTTP helper (timeouts, retries on rate limits and server
  errors only, token and latency counts) that a custom adapter may use.
- **Security:** the API key lives in the adapter only: never in a response, a log line, a saved eval run or `inspect`. What leaves the
  app is the prompt, the role's catalog (or the router's index) and the user's question, never rows.

Rejected: a high-level adapter with `route` and `query` (B: one prompt per provider, outside the eval, rewritten by every integrator);
a bare callable with no shipped adapter (C: nothing works without code, and every integrator writes the schema translation).

## D2 — OpenAI first, the others when a measurement needs them (decided, "A")

- **Why OpenAI:** by its documentation, the only one whose strict mode takes a whole catalog once translated, which the naive baseline
  (T13) needs. The author holds keys for OpenAI, Gemini, Mistral and DeepSeek.
- **The others, each with its own ticket and eval run:** DeepSeek has a JSON mode only (valid JSON, no schema enforced), so it measures
  what strict mode is worth; Gemini or Mistral for a comparison between providers, once their limits are tried.
- **Keys:** read from `ENV` by the host app's configuration; the dummy app reads `OPENAI_API_KEY`. No `dotenv`: a `.env` (git-ignored)
  is loaded by the shell. The CI never calls a provider: specs use a fake transport, real eval runs are started by hand.

- **First real call** (2026-11-08, `gpt-5.4-mini-2026-03-17`, the admin schema, one question): refused twice for rules the documentation
  does not list, every schema needing a `type` (our `const` and `enum` had none) and `uniqueItems` not permitted; accepted once both
  were translated. 6,583 input tokens, 65 output tokens, 2.2 s; the validator accepted the query. One call, not a measurement.

Rejected: OpenAI and DeepSeek at once (B: two transports before the first one is tried); one "OpenAI-compatible" adapter switched by URL
(C: a compatibility not verified, and the providers differ precisely on structured outputs).
