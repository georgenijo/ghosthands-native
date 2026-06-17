# DESIGN.md — GhostHands-native spec

The *why* and *how*. State + roadmap live in [ROADMAP.md](./ROADMAP.md); rules in
[AGENTS.md](./AGENTS.md); the running decision log in
[docs/decisions/DECISIONS.md](./docs/decisions/DECISIONS.md).

## The product thesis

A model-agnostic, local macOS computer-use tool whose two non-negotiables are
**invisibility** (acts on background windows; never steals the cursor or focus)
and **honesty** (never claims an effect it can't observe). Everything else —
more verbs, the brain, the phone bridge — is built on those two.

The endgame: **anything on the Mac screen is agent-interactable, triggered from
your phone**, with every step world-verified. See ROADMAP's capability matrix
(target: every row ✅).

## Why AXorcist, not cua-driver

A scored read-only eval (DECISIONS.md) compared both as the actuation core.
AXorcist (MIT) won on the two decisive axes: **license** (cua ships no LICENSE →
all-rights-reserved + telemetry, can't be vendored into a repo we own; AXorcist
is MIT) and **hard surfaces** (AXorcist ships menu-bar/dialog/window/multi-monitor
support; cua has none). Honesty was a wash — *both* need a verification layer
added — and AXorcist's open Swift makes that clean to bake in.

## Architecture (the unified repo)

- **Hands** = AXorcist (Swift, MIT) — the AX read/act primitives.
- **Core** (`GhostHandsKit`) = resolve → find → act → verify, with the honesty
  contract. Pure logic (name scoring, resolution, verdict) is split from the AX
  bridge so it is unit-testable without a live app.
- **CLI** (`ghosthands`) = the verbs + honest exit codes.
- **Future:** a long-lived daemon + `AXObserver` push-events (M5), a
  goal-seeking brain (M6, model-agnostic — local model is a plugin off the hot
  path), and the remote phone bridge + auth (M7).

The seam stays Swift end-to-end; collapsing to one language unlocks event-driven
(not poll-based) automation, a single TCC identity, one daemon, and streaming
results to a phone — things a two-process seam can't give.

## The honesty model

`press()` returning success means the AX layer **dispatched** the action — NOT
that the world changed. So a verdict has three levels:

- **verified** — `valueBefore != valueAfter`, OR the target no longer matches on
  a fresh snapshot (relabelled / vanished). Real observed change.
- **dispatched (unverified)** — AX accepted, but the element exposes no
  observable change (e.g. a plain button: no `AXValue`, still present). We say
  "AXPress accepted; effect unverified" — humility, not a success claim.
- **refuse** — not found / ambiguous / AX-rejected → exit ≠ 0.

**Effect-witness (M2):** to upgrade a button press from "unverified" to
"verified", read a *sibling* element (e.g. Calculator's display) before/after.
That turns "pressed 7,8,9 → unverified" into "verified: 0 → 789". This is the
single biggest honesty upgrade and M2's centrepiece.

## The click pipeline (per action)

```
resolve app            NSWorkspace: name / bundle id / pid  (refuse if >1 distinct)
  → app AX element     Element(AXUIElementCreateApplication(pid))
  → search the tree    AXorcist searchElements(matching: name)
  → keep candidates    actionable (control role) + enabled; exclude menus/static text
  → resolve            exact beats substring; collapse duplicate-window renders;
                       >1 distinct ⇒ REFUSE (ambiguous)
  → read BEFORE        the control's value (may be nil)
  → press()            AXUIElementPerformAction(AXPress) — no cursor, no focus
  → re-find FRESH      same control by identity on a new snapshot; read AFTER
  → verdict            verified | dispatched-unverified | (refuse paths above)
```

## Why AX, not pixels

A pixel/synthetic click needs the window foreground + moves the cursor + can land
on the wrong thing. An **AX action** addresses the control directly, works on a
backgrounded/occluded window, steals no focus, and moves nothing on screen. That
is the entire reason this can run while you keep using your Mac — and the reason
it can eventually run from your phone without hijacking the machine.
