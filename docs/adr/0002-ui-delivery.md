# ADR 0002 — UI delivery: command palette as a web component

Status: accepted

Context: the UI is a command palette (Ctrl/Cmd+K) injected into every page of the host app, with an
inline mode for the same component. The gem must install in any Rails SaaS, whatever its JS stack.

## Decision

A custom element (`<data-teller-palette>`) written in vanilla JS, rendered through a view helper, built on the
native `<dialog>` element (focus, Esc, accessibility). The server returns HTML fragments; no framework on the host side.

Configuration (inside `DataTeller.configure`):

```ruby
config.ui.mode = :modal                # :modal | :inline (inline = same component in a page, e.g. the mounted /ask route)
config.ui.theme = :system              # :system | :light | :dark (CSS variables + prefers-color-scheme)
config.ui.keyboard_shortcut = "mod+k"  # nil disables it
```

Why: no requirement on the host (Stimulus/importmap would exclude esbuild, Vite or React apps);
it is also the natural shape of the V2 embeddable component.

Guard rails:
- The shortcut is configurable (conflicts with browser search focus and existing palettes), ignored while typing
  in an input, and always paired with a visible trigger button (discoverability, mobile).
- Security: helper renders only for an authenticated and authorized user, the endpoint re-checks; CSRF token on
  every fetch; no inline script or style (CSP); user-provided values escaped in explanations.
- Performance: JS loaded on first open, dialog content fetched on open.
- No CSS framework: a small stylesheet with custom properties.

Rejected: Stimulus controllers (host must have Stimulus + importmap), Turbo Frames only (host must have Turbo),
Phlex (extra dependency). Herb stays an optional dev-only ERB linter.
