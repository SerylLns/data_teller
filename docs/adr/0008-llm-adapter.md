# ADR 0008 — The LLM adapter

Status: D1 accepted (2026-11-08); D2 open

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

## D2 — The first provider shipped

Open. Depends on which provider the author has a key and a budget for. ADR 0007's reading of the documentation favours OpenAI for strict
mode on a whole catalog (T13); after routing (T13c), the narrowed schema may also fit Anthropic's limits.
