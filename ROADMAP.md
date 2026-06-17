# GhostHands-native — Roadmap & State

**One line:** a tool that clicks/controls any macOS app **invisibly** (no cursor
move, no focus steal) through the Accessibility tree, and is **honest** — it
proves the effect, says "pressed but unproven", or refuses; it never fakes
success.

**North star:** GhostHands-native should eventually do **everything** in the
capability matrix below — every row a ✅ — and be controllable **from your
phone**. This file is the single handoff doc; read it first in a new session.

---

## Where things live

- **This repo:** `/Users/george-mac-mini/Documents/code/ghosthands-native` →
  `github.com/georgenijo/ghosthands-native` (private). Branch `main`.
- **Hands library:** [AXorcist](https://github.com/steipete/AXorcist) (MIT),
  SwiftPM dep pinned `exact: 0.1.2`. Source checkout to read its API:
  `.build/checkouts/AXorcist/Sources/AXorcist/`.
- **Decision log (canonical, in the Python repo):**
  `/Users/george-mac-mini/Documents/code/ghosthands/docs/decisions/DECISIONS.md`
  — entries for M1, and "hands core = AXorcist not cua" (with the scored eval).
- **Old GhostHands (Python, the renter):**
  `/Users/george-mac-mini/Documents/code/ghosthands` — rides cua-driver; has
  more verbs but borrows a closed-source daemon. Being superseded by this repo.
- **Peekaboo (MIT, the rival/superset):**
  `/Users/george-mac-mini/Documents/code/peekaboo` — broad surface, but fakes
  `success: true` and moves the cursor. We mine its techniques (MIT).

## Build / test / run (works on this machine: Swift 6.3.2, Xcode 26.5)

```sh
cd /Users/george-mac-mini/Documents/code/ghosthands-native
swift build            # builds (uses only AXorcist; dodges Peekaboo's Xcode-27 app target)
swift test             # 16 hermetic tests (no live app driven)
.build/debug/ghosthands click "<name>" <app>     # e.g. click "7" Calculator
.build/debug/ghosthands version
```

**Live-verify recipe (don't trust your own memory of acting):** launch a target
app in the *background* via the cua-driver MCP (`launch_app`), drive it with
`ghosthands`, then world-check with cua `get_window_state` + `get_cursor_position`
+ `list_apps` (target must stay `active:false`). Calculator is fine for a live
demo; **never** drive a live app in the unit tests (George's rule — tests are
hermetic with fabricated facts). Don't press destructive controls in real apps
(OrbStack has live containers — avoid Stop/Trash/Play).

---

## Capability matrix — NOW vs the all-✅ target

| Capability | Old GH (Py) | Peekaboo | **native NOW** | **native TARGET** | Milestone |
|---|---|---|---|---|---|
| Click named control, invisible (background, no focus steal, no cursor move) | ✅ | ✅ | ✅ | ✅ | done (M1) |
| Honest verdict: verified / pressed-unproven / refuse | ~ | ❌ | ✅ | ✅ | done (M1) |
| Owns its hands (no borrowed daemon) | ❌ | ✅ | ✅ | ✅ | done (M1) |
| Refuse on ambiguity (don't guess the wrong control) | ❌ | ❌ | ✅ | ✅ | done (M1) |
| Read the screen (snapshot / find / screenshot) | ✅ | ✅ | ❌ | ✅ | **M2** |
| Prove effects (effect-witness: read a sibling, e.g. the display) | ~ | ❌(AI guess) | ❌ | ✅ | **M2** |
| Type text (honest: set-value + verify it changed) | ❌ | ✅ | ❌ | ✅ | M3 |
| Double-click / open files / NSOpenPanel dialogs | ✅ | ✅ | ❌ | ✅ | M3 |
| Toggle checkbox / move slider / pick dropdown (set-value) | ~ | ✅ | ❌ | ✅ | M3 |
| Named AX actions (open/confirm/pick/show_menu/cancel/raise) | ✅ | ✅ | ❌ | ✅ | M3 |
| record / replay a flow (no model) | ✅ | ❌ | ❌ | ✅ | M3 |
| Menu bar + Control Center | ❌ | ✅ | ❌ | ✅ | M4 |
| Drag-and-drop (install app: DMG → Applications) | ❌ | ✅ | ❌ | ✅ | M4 |
| Multi-monitor + window identity/management | ❌ | ✅ | ❌ | ✅ | M4 |
| Web tier (tabs / bookmarks / read page) | ✅(cua) | ✅ | ❌ | ✅ | M4 |
| Always-on daemon + push-events (react instantly) | ❌ | ❌ | ❌ | ✅ | M5 |
| Brain: goal → plan → act → verify (model-agnostic) | ✅(local) | ✅ | ❌ | ✅ | M6 |
| **Phone bridge: text from phone → runs on Mac + auth** | ❌ | ❌ | ❌ | ✅ | **M7** |

`~` = partial. The TARGET column is all ✅ on purpose — that's the goal.

---

## Milestones to fill every checkmark (mapped to the 4-layer vision)

- **M2 — Read + Prove** *(Layer 1 read + Layer 2 honesty finisher).* Bring back
  `snapshot` / `find` / `shot`. Add the **effect-witness**: after a press, read a
  *sibling* element (e.g. Calculator's display) so a digit press comes back
  **verified** ("0 → 789") instead of today's honest "unverified". This is the
  next build and the highest-value honesty upgrade.
- **M3 — More actions** *(Layer 1).* `type` (AX set-value, verify the value
  changed — never the old keystroke no-op), `doubleclick`, `set-value` for
  checkbox/slider/dropdown, the named AX actions, and record/replay.
- **M4 — Hard surfaces** *(Layer 1, the credibility 20%).* Menu bar / Control
  Center, drag-and-drop (the "install an app" demo — prefer `cp -R` over GUI
  drag when possible), multi-monitor + window management, web tier.
- **M5 — Always-on** *(Layer 2).* Long-lived daemon + `AXObserver` push-events
  (react the instant a dialog appears) + lifecycle/auto-heal. One TCC identity.
- **M6 — Brain** *(Layer 3).* Goal-seeking loop, model-agnostic (cloud Claude by
  default; local model = a plugin off the action hot path), prefer-reliable-path
  planning (filesystem/`defaults`/AX before GUI mimicry).
- **M7 — Phone bridge** *(Layer 4, the dream).* Remote ingress (phone → Mac),
  auth/gating (token, allowlist, confirm-before-destructive, audit log), result
  streaming back. "Text it a task, it runs on your Mac."

North-star demo for "done": from your phone, *"install Rectangle"* → download
DMG → mount → handle the license dialog → install → eject → launch → confirm
running — every step world-verified.

---

## Architecture decisions already locked (don't re-litigate)

- **Hands = AXorcist (MIT), not cua-driver.** cua is closed-source (no LICENSE
  file → all-rights-reserved) + telemetry → can't vendor into a repo we own.
  AXorcist is MIT and ships the hard surfaces. Scored eval in DECISIONS.md.
- **One unified repo, two languages:** Swift hands + (future) Swift conductor;
  the brain is the one place a second language (Python/MLX local model) may live,
  as a plugin off the hot path. Collapsing to all-Swift unlocks push-events, one
  TCC grant, one daemon, streaming to phone.
- **Honesty is the differentiator.** Never hardcode success. `verified` requires
  an observed world-change; otherwise say "dispatched, effect unverified";
  refuse on not-found / ambiguous / rejected.

## Gotchas a fresh session will hit

- AXorcist getters (`role()/title()/value()/children()/searchElements`) are
  `@MainActor` — the CLI entry is `@MainActor`.
- `Element.supportedActions()` (a generic attribute fetch) can return **nil even
  for a genuinely pressable AXButton** → we gate candidates on a **control-role
  allowlist** (`Finder.controlRoles`), not on AXPress alone.
- `press()/pick()/showMenu()` return `Bool` (false = AX rejected). App element =
  `Element(AXUIElementCreateApplication(pid))`. Name→app via `NSWorkspace`.
- Apps can render **two AXWindow subtrees** (duplicate) → we collapse by identity.
- Menus are excluded from `click` (frontmost-only concern) — that's M4's job.
- AX path needs **Accessibility** permission only (no Screen Recording). The
  launching terminal already holds the grant on this machine.

---

## Resume (new session)

The canonical operating contract + the `/loop` resume prompt live in
**[AGENTS.md](./AGENTS.md)** (§"Resume"). Shortest path: open a fresh session and
run it as a `/loop` prompt — *"Continue GhostHands-native per AGENTS.md +
ROADMAP.md; churn milestones in order; start M2; stop at M4+ / outward-facing /
forks."* The repo carries everything (this file, AGENTS, DESIGN, decisions,
CHANGELOG) — no external context needed.
