# Changelog

## 0.1.0-m1 — 2026-06-17

First milestone. The honest, invisible click core.

**Added**
- `ghosthands click "<name>" <app>` — press a named control through the
  Accessibility tree: cursor-less, background-safe, no focus steal. App resolves
  by name / bundle id / pid; control by title / label / value / identifier /
  description.
- Honesty model: every action is **verified** (observed change), **dispatched
  (unverified)** (AX accepted, no observable proof), or **refused** (not found /
  ambiguous / AX-rejected → exit ≠ 0). Never a hardcoded success.
- Safety: only actionable + enabled controls are candidates (no static text, no
  menus); ambiguity (>1 distinct control, or >1 partial app match) refuses;
  duplicate-window renders collapse by identity; read-back is identity-pinned on
  a fresh snapshot.
- `GhostHandsKit` (Target / Finder / Click / Errors) + `ghosthands` CLI.
- 16 hermetic unit tests (pure name-resolution + verdict logic; no live app).
- Docs: README, ROADMAP, DESIGN, AGENTS, ATTRIBUTION, decision log.

**Built on** AXorcist (MIT). See ATTRIBUTION.md.

**Verified** live against a backgrounded Calculator (world-checked via an
independent snapshot): presses land, cursor never moves, the app never
foregrounds; verified-by-relabel and honest "unverified" both demonstrated;
unknown names refuse.

**Not yet** (see ROADMAP): read verbs, effect-witness, type, dialogs, the hard
surfaces, the daemon, the brain, the phone bridge.
