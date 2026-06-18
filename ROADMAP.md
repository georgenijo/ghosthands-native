# GhostHands-native — Roadmap & State

**One line:** a tool that clicks/controls any macOS app **invisibly** (no cursor
move, no focus steal) through the Accessibility tree, and is **honest** — it
proves the effect, says "pressed but unproven", or refuses; it never fakes
success.

**North star:** a COMPLETE, honest, invisible macOS computer-use **tool that any
agent can plug into and drive the whole Mac** — every row of the capability
matrix below a ✅. This tool is the **hands + eyes**, exposed as a clean
interface (MCP server / CLI / Swift library). The **brain, the phone, and
"text-it-a-task" are OUT OF SCOPE** — George owns those and plugs in whatever
agent he wants; this tool just lets that agent *do anything on screen*,
invisibly and honestly. This file is the single handoff doc; read it first in a
new session.

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
| Read the screen (snapshot / find / screenshot) | ✅ | ✅ | ✅ | ✅ | done (M2) |
| Prove effects (effect-witness: read a sibling, e.g. the display) | ~ | ❌(AI guess) | ✅ | ✅ | done (M2) |
| Type text (honest: set-value + verify it changed) | ❌ | ✅ | ✅ | ✅ | done (M3) |
| Double-click / open files / NSOpenPanel dialogs | ✅ | ✅ | ✅ | ✅ | done (M3) |
| Toggle checkbox / move slider / pick dropdown (set-value) | ~ | ✅ | ✅ | ✅ | done (M3) |
| Named AX actions (open/confirm/pick/show_menu/cancel/raise) | ✅ | ✅ | ✅ | ✅ | done (M3) |
| record / replay a flow (no model) | ✅ | ❌ | ✅ | ✅ | done (M3 pass-2) |
| Menu bar + Control Center | ❌ | ✅ | ❌ | ✅ | M4 |
| Install app (DMG → Applications, cp -R + verify bundle) | ❌ | ✅ | ✅ | ✅ | done (M4) |
| Multi-monitor + window identity/management | ❌ | ✅ | ❌ | ✅ | M4 |
| Web tier (read page) | ✅(cua) | ✅ | ✅(Chromium+Safari) | ✅ | done (M4, AX-wake) |
| Web tier (tabs / bookmarks) | ✅(cua) | ✅ | ~(no AXTabGroup) | ✅ | M4 (CDP = future) |
| Always-on daemon + push-events (react instantly) | ❌ | ❌ | ❌ | ✅ | M5 |
| **Pluggable interface (MCP server) — any agent can drive it** | ❌ | ✅ | ✅ | ✅ | **done (M5 scaffold)** |

`~` = partial. The TARGET column is all ✅ on purpose — that's the goal.

**Out of scope (NOT this tool's job — George owns it):** the brain / goal-planner,
the phone ingress, "text-it-a-task", auth for remote control. This tool is the
hands + eyes; whoever plugs in brings the brain.

---

## Milestones to fill every checkmark (M2–M5 — the complete tool)

- **M2 — Read + Prove** ✅ *(Layer 1 read + Layer 2 honesty finisher).* `snapshot`
  / `find` / `shot` shipped; the **effect-witness** promotes a plain digit press
  to **verified** (`value:0 → value:789`) by reading a settled, window-scoped
  sibling readout — causally fenced (stability gate, exactly-one-change,
  structural keys) so it never over-claims. Done: live-verified on a backgrounded
  Calculator + 69 hermetic tests. (M5 backlog: bound AX calls — `searchElements`
  can hang on a degraded AX subsystem.)
- **M3 — More actions** ✅ *(Layer 1, mutating verbs on the shared honesty core).*
  `type` (AX set-value then **read the value back** — never the keystroke no-op;
  a set the field accepts but doesn't hold is honest DISPATCHED-UNVERIFIED, never
  success; a secure field is REFUSED as unverifiable), `set-value` for
  checkbox/slider/dropdown (value type-COERCED, uncoercible REFUSED), `doubleclick`
  (AXOpen-preferred), and the named AX actions (`act open|confirm|pick|show-menu|
  cancel|raise|increment|decrement`, advertise-check pre-gate, increment/decrement
  verified by numeric direction). All four share one `EffectProbe`
  (window-pinned + settle-twice witness fence, extracted from the click path) and
  refuse on not-found / ambiguous / AX-reject. Done: 120 hermetic tests, adversarial
  honesty review, and `type` live-verified on a backgrounded TextEdit
  (`value "…" → "VERIFIED-LIVE-0618"`, world-checked via an independent cua read,
  app `active:false`). Live-verify also surfaced + fixed a real read bug —
  `AXTextArea`/`AXTextField` values read back as nil (so `type` could never verify
  a real set, and `snapshot`/`find` missed field contents); fixed with a raw
  `AXUIElementCopyAttributeValue` fallback. **record/replay deferred to M3 pass-2.**
- **M4 — Hard surfaces** *(Layer 1, the credibility 20%).* Menu bar / Control
  Center, drag-and-drop (the "install an app" demo — prefer `cp -R` over GUI
  drag when possible), multi-monitor + window management, web tier.
  *Progress (0.4.1):* **web read now works on Chromium** — a one-line
  `AXManualAccessibility` wake on the browser app element makes Brave/Chrome
  publish their `AXWebArea`; live-verified reading a real Brave page (163
  elements), AX-only, honesty floor intact. `web tabs` still refuses where no
  `AXTabGroup` is exposed (CDP path = future). **pixel `--visible` HID mode**
  added — `click-at`/`drag` can actuate via a real `.cghidEventTap` click
  (labelled exception: moves the cursor, may steal focus, OS routes to the
  screen-front window — not invisible); default stays cursor-less best-effort.
  *Still open in M4:* menu bar / Control Center, drag-install, multi-monitor +
  window identity, web tabs/CDP.
- **M5 — Pluggable + always-on (the endgame).** Expose the whole verb surface as
  an **MCP server** (plus the CLI + a Swift library) so **any agent** — Claude, a
  phone agent, anything — can plug in and drive the Mac. Long-lived daemon +
  `AXObserver` push-events (react the instant a dialog appears) + lifecycle /
  auto-heal. One TCC identity. After M5 this is a complete, honest, invisible
  macOS computer-use tool, ready for any brain to use.

**Done** = every capability-matrix row ✅: an agent plugged into the MCP can
drive *anything on screen* — read it, click it, type it, toggle it, drag it,
across monitors and menus — invisibly and honestly. E.g. an agent installs
Rectangle end-to-end (DMG → dialog → install → launch → verified) with zero focus
theft. The agent/brain doing the driving is George's, not this tool's.

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
