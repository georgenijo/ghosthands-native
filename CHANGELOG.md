# Changelog

## 0.2.0-m2 — 2026-06-17

Read + Prove. The eyes, and the honesty finisher for `click`.

**Added**
- `ghosthands snapshot <app> [--ax|--json]` — dump the app's window AX tree
  (pure read, no focus steal). Settle-and-retry on a cold/empty first read.
- `ghosthands find "<name>" <app>` — does a named element exist? Substring match
  across all roles incl. static text (NOT actionable-only, unlike `click`); exit
  0 found / 1 missing.
- `ghosthands shot <app> <out.png>` — honest screenshot via ScreenCaptureKit.
  REFUSES (no file, exit ≠ 0) without Screen Recording — never a black PNG sold
  as success. Bootstraps the WindowServer connection so a bare CLI captures
  without aborting (`CGS_REQUIRE_INIT`), and without activating / stealing focus.
- **Effect-witness** — the headline honesty upgrade. A plain button (no value of
  its own) is now promoted to **verified** when a value-bearing *sibling* settles
  to a new value: a digit press reports `verified: … value:0 → value:789` instead
  of M1's honest "unverified". Causally fenced so it never over-claims:
  - window-scoped (the witness must be in the pressed control's own window,
    matched by stable CGWindowID — never a positional fallback to "window 0");
  - exactly-one-change (2+ changed → demote to unverified, never guess);
  - **stability gate** (a witness must hold the same value across two post-press
    reads — a live clock / animation keeps moving and is dropped);
  - structural identity keys (role+title+frame+tree-path), so a value flip is
    never misread as a disappearance and colliding siblings are dropped, not
    fabricated into a change;
  - the readout is `AXValue`; the identifier/description fallback (for an
    `AXScrollArea` that carries its value on the id, e.g. the modern Calculator
    display) is scoped to that one carrier role.
- Honesty fix in `axString`: peel a boxed `Optional<Any>.some(.none)` so an empty
  AX value reads as `nil`, not the literal string `"nil"` — `snapshot` no longer
  prints fabricated values and the witness can see a true `nil → value` change.
- 53 new hermetic tests (69 total): witness diff, stability fence, readout
  precedence, snapshot render, find matching, shot decision — all fabricated
  facts, no live app driven.

**Verified** live against a backgrounded Calculator (world-checked via an
independent cua snapshot + screenshot): `snapshot` dumps the tree, `find`
hits/misses with honest exit codes, the effect-witness reports
`verified: value:0 → value:7 → value:78 → value:789` on plain digit presses,
`shot` writes a real window-scoped PNG showing `789`, the cursor never moves and
the app stays `active:false`. (The post-review honesty-hardening — window-id
anchoring, stability fence, readout narrowing — is hermetically verified; its
live re-demo was blocked by a transient system AX-subsystem wedge, see below.)

**Known robustness gap (M5):** AXorcist's `searchElements` and raw AX attribute
reads are **unbounded** — if the OS accessibility subsystem is degraded (e.g.
after an AX client is SIGKILL'd mid-transaction) a search can hang the CLI with
no timeout. `snapshot`'s strict-children walk is unaffected. Bounded AX calls /
per-call timeouts are an M5 hardening item.

**Built on** AXorcist (MIT). See ATTRIBUTION.md.

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
