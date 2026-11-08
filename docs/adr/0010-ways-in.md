# ADR 0010 — The ways in: `DataTeller.ask`, the endpoint, the helper, and who is asking

Status: accepted (2026-11-08)

Context: T13b is the gem's first endpoint, so for the first time the gem has to find out who is asking. Until now `QueryRunner` was handed a user.
Integrators may also want another visual than the palette (ADR 0002).

## D1 — Three layers, each on the one before

1. **`DataTeller.ask(question, user:)`, the Ruby API.** A question and a user in, an outcome out: rows, a clarification or a refusal. For any other visual: a chart of
   their own, a chat bot, a JSON API. Roles, the validator and the tenant filter are all under it, so no visual can go around them.
2. **`POST /ask`, the engine's endpoint**, answering an HTML fragment (ADR 0002).
3. **`data_teller_palette`, the view helper**, modal or inline according to `c.ui.mode`.

The gem ships no charts, and no JSON on its endpoint.

## D2 — The endpoint finds the user through a block (decided, "A")

```ruby
c.current_user { |request| request.env["warden"]&.user }                  # Devise
c.current_user { |request| User.find_by(id: request.session[:user_id]) }  # own sessions
```

- Same shape and same rule as `c.tenant` and `c.roles`: no block, nil or an error all mean no access. The helper uses the same block, so the palette and the endpoint agree.
- **Why:** nothing of the host runs on the gem's most sensitive path. A `before_action` added to the host's `ApplicationController` cannot change what the endpoint does without anyone noticing, nor answer a `fetch` with a login redirect.
- **Limit:** the host's `before_action`s do not run. If its `current_user` depends on what they set up, the block has to find it again. An integrator who wants the host's filters writes a controller of their own and calls `DataTeller.ask`, passing the user.

Rejected: the gem's controller inheriting from the host's (B: every filter, redirect and layout of the host comes along, and can change the endpoint's behaviour silently); a module for the host to include in a controller it writes (C: the palette no longer works by mounting the engine, and the checks depend on the integrator's code; `DataTeller.ask` covers that need).
