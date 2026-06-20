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
| Menu bar (regular app menus — File/Edit/View…) | ❌ | ✅ | ✅ | ✅ | done (`menu` verb, 0.8.2) |
| Control Center / MenuBarExtra (status items) | ❌ | ✅ | ❌ | ✅ | DEFERRED (hard: MenuBarExtra AXPress no-op) |
| Install app (DMG → Applications, cp -R + verify bundle) | ❌ | ✅ | ✅ | ✅ | done (M4) |
| Multi-monitor + window identity/management | ❌ | ✅ | ✅ | ✅ | done (M4) |
| Web tier (read page, with element frames) | ✅(cua) | ✅ | ✅(Chromium+Safari) | ✅ | done (M4, AX-wake) |
| Web tier (tabs / bookmarks) | ✅(cua) | ✅ | ✅(CDP incl. background tabs) | ✅ | done (overnight, CDP S1) |
| Navigate to a URL (verify page changed) | ✅(cua) | ✅ | ✅ | ✅ | done (M4) |
| Press keys / hotkeys (Enter / Tab / chords) | ✅(cua) | ✅ | ✅(dispatched) | ✅ | done (M4) |
| Always-on daemon + push-events (react instantly) | ❌ | ❌ | ❌ | ✅ | DEFERRED (issue #2 — needs design) |
| **Pluggable interface (MCP server) — any agent can drive it (FULL 31-tool surface)** | ❌ | ✅ | ✅ | ✅ | **done (M5)** |
| Web selector click / fill (CDP) + occlusion "covered-by" refuse | ✅(cua) | ✅ | ✅ | ✅ | done (overnight, CDP S2) |
| Web DOM read — outerHTML / computed / attrs + JS eval (CDP) | ❌ | ~ | ✅ | ✅ | done (overnight, CDP S3) |
| Web consent-gated isolated relaunch (ephemeral port + sidecar) | ✅(cua) | ✅ | ✅ | ✅ | done (overnight, CDP S4) |
| Keyboard focus (focus verb + auto-focus-on-type) | ❌ | ~ | ✅ | ✅ | done (overnight) |
| Right-click / context menu (menu-appeared witness) | ❌ | ✅ | ✅ | ✅ | done (overnight) |
| Scroll within scroll-areas/lists (position witness) | ❌ | ✅ | ✅ | ✅ | done (overnight) |
| Drag element → element (witnessed) | ❌ | ✅ | ✅ | ✅ | done (overnight) |
| Extract table/outline/list as structured rows ("collect anything") | ❌ | ~ | ✅ | ✅ | done (overnight) |
| Detect + respond to a modal sheet / alert / dialog | ❌ | ✅ | ✅ | ✅ | done (overnight) |
| Deterministic wait / poll (exists / gone, hard deadline) | ❌ | ❌ | ✅ | ✅ | done (overnight) |
| Assert / expect verbs (exists/absent/value/count, exit codes) | ❌ | ❌ | ✅ | ✅ | done (overnight) |
| Clipboard read / write (read-back verify) | ❌ | ✅ | ✅ | ✅ | done (overnight) |
| Locator disambiguators (--nth / --role / --text) | ❌ | ✅ | ✅ | ✅ | done (overnight) |
| --json result envelope on every verb (stable schema) | ❌ | ~ | ✅ | ✅ | done (overnight) |
| Opt-in failure artifacts (screenshot + JSONL log on refuse) | ❌ | ❌ | ✅ | ✅ | done (overnight) |
| Cycle-safe / bounded AX (no SIGSEGV/hang on macOS-26 cyclic trees) | ~ | ❌ | ✅ | ✅ | done (overnight) |

`~` = partial. The TARGET column is all ✅ on purpose — that's the goal. Every row is
now ✅ **except** the two George explicitly deferred — menu bar / Control Center (hard,
MenuBarExtra AXPress is a no-op) and the always-on daemon (issue #2, needs a design
discussion). The other deferred forks: vision/OCR (#1), UI-test flow-runner (#3),
packaging/notarization (#4).

**Real-life stress test (0.8.0-m4):** a fresh zero-context agent drove ghosthands
through 11 live web + cross-app tasks — **11/11, honest throughout, ~16s of tool time
out of 439s (rest was page/network), no crashes/wedges, no fake successes.** Full report
in [`docs/STRESS-TEST-0.8.0.md`](./docs/STRESS-TEST-0.8.0.md). It earned two tickets:
**#5** (give `type`/`set-value` the same `--nth`/`--role`/`--text` disambiguators as
`click`) and **#6** (`web click` post-click DOM read-back so in-page toggles earn
VERIFIED).

**Web ergonomics parity (vs agent-browser).** The same 11-task battery was then run
through **agent-browser 0.27.0** (native verbs only) as a head-to-head. Both cleared
every browser task; agent-browser's two misses were structural (can't drive a native
app, bundled Chromium can't play DRM video), and it printed `✓ Done` on a fill that
silently no-op'd — ghosthands stayed verify-or-refuse throughout. Verdict: ghosthands
already **wins on capability + honesty**, loses only on **driving ergonomics**. The gap
is one thing — `web read` (look) and `web click`/`web fill` (act) don't share a handle,
so every click costs a look + a hand-written selector, and name collisions refuse. Fix =
**numbered `@ref` handles shared by read + act** (also the best answer to "semantic
find"; a see-the-words backup folds in). Full comparison, plain-English explanation, and
locked design: [`docs/WEB-PARITY.md`](./docs/WEB-PARITY.md). Work-list (all keep the
honesty contract): **#7** `@ref` addressing (P0), **#9** managed `web open`/`web close`
session (P0), **#10** page-side `web wait` (P0), **#8** form-control state in `web read`
(P1), **#11** no-JS `web text/attr/count` (P1). Loop order: #7 → #9 → #10 → #8 → #11,
with #5/#6 slotted where they touch the same files.

Status (branch `feat/web-parity`): **#7 ✅ shipped** — the CDP `web read` stamps
`@eN` on every interactive element; `web click`/`web fill`/`web html` accept the
ref (resolving it to a `data-gh-ref` attribute selector) AND raw CSS (additive); a
ref whose stamped element is gone after a nav/re-render REFUSES (`staleRef`,
"re-read"). Live-verified on example.com→iana (click-by-ref VERIFIED via
navigation) and html.duckduckgo.com (fill-by-ref VERIFIED via read-back). The
see-the-words find backup is the scheduled tail item (after #11).

**#9 ✅ shipped** — `web open [--headed] <url> [browser]` launches an ISOLATED
throwaway instance (OS-chosen port, fresh temp profile), waits until a driveable
page is listed, and persists a session handle; subsequent `web read/click/fill`
auto-target it (no `--debug-port`, browser arg optional). `web close` terminates
it (plain SIGTERM) and removes the temp profile — zero leftovers. Live-verified
end-to-end with George's real Brave running concurrently: the real default
profile was NEVER touched (the throwaway ran on its own temp profile, and close
killed only the throwaway pid).

**#10 ✅ shipped** — `web wait --text/--url/--selector(+--gone)/--load
domcontentloaded|networkidle` page-side condition waits over CDP, the web analogue
of AX `wait`: hard wall-clock deadline + the same deadline fence, elapsed/poll
evidence, and a timeout that REFUSES (`waitTimeout`, never a fabricated met).
networkidle uses an honest page-side quiet-network heuristic (readyState complete
+ resource-timing idle window) since the CDP session has no event stream.
Live-verified: a full example.com→iana navigation + content-appearance flow
sequenced with `web wait` alone — no `curl`, no `web eval` poll loops.

**All three P0s (#7 + #9 + #10) shipped green.**

**#8 ✅ shipped** — `web read` surfaces form-control state inline
(`checked`/`selected`/`expanded`/`(disabled)`), so a toggle is verifiable in one
read; a stateful-but-unlabeled control is kept, not dropped. **#11 ✅ shipped** —
no-JS extraction verbs `web text`/`web attr`/`web count` (`--all` for every match)
+ scoped `web read --in <css>`; invalid/no-match REFUSES, `count` of nothing is an
honest 0. Live-verified extracting HN top-5 (titles + points + links) with no
`web eval`.

**#7 see-the-words backup ✅ shipped** — `web click/fill --text "<visible>" [--nth N]`
addresses by what a human reads (visible text / field label), re-resolved live,
ranks ties + reports the pick, refuses on no-match / out-of-range. Live-verified.

**Web-ergonomics parity: GAP CLOSED.** All five work-list issues green; the web
subset of the 11-task battery re-run with the new verbs (HN refs+extraction, the
form-state checkbox toggle proven by re-read, the DuckDuckGo find-backup fill) —
agent-browser's driving feel, ghosthands' honesty + native reach kept. See
[`docs/WEB-PARITY.md`](./docs/WEB-PARITY.md) verdict. Optional polish left: #6
(post-click DOM read-back) + #5 (native `--nth`/`--role`/`--text`).

**Feature A — "drive any app" turnkey (in progress).** Closing the two Electron
gaps the Cursor walkthrough exposed: a keybinding-only command can't be fired, and
multi-window Electron forces guessing which renderer. Three looped slices:
- **A1 ✅ shipped (0.8.9-m4)** — `web key "<chord>" <browser>` fires an app
  keybinding/accelerator over CDP `Input.dispatchKeyEvent` (the ⇧⌘L-class command AX
  can't reach), always dispatched-unverified; **`--target <n|title>`** picks WHICH
  CDP page/renderer the web verbs drive (default first, no-match REFUSES). Pure
  `CDPKeySpec`/`CDPTargetPick` hermetically tested; live-verified on an isolated
  throwaway Brave (a `keydown` handler received `cmd+shift+L` exactly; `--target`
  index/substring refuse paths proven). 37th MCP tool. Honesty review PASS.
- **A2 ✅ shipped (0.8.10-m4)** — `see <app>` fuses AX + CDP DOM + Vision OCR into ONE
  ranked, de-duplicated, `@ref`-stamped list (ref, role, name, rect, source, tier) and
  persists the ref→record map for `act`. Visible+interactive+named ranked first; dedup
  keeps the most-actuatable source (cdp>ax>ocr) and won't drop a distinct same-named
  control (per-source name-uniqueness gate); CDP eye never pulls an unrelated browser
  into a native view. Pure fusion hermetically tested (789 total). 38th MCP tool. Live-
  verified (AX on Finder, CDP on a throwaway Brave). Honesty review PASS.
- **A3 ✅ shipped (0.8.11-m4)** — `act "@ref" <app> [--type] [--submit]` resolves a ref
  from the last `see` and AUTO-PICKS the hand by source (AX press/type, CDP click/type,
  HID click), delegating to the proven per-tier verb (verify-or-refuse). Staleness gates
  refuse on no-snapshot / app-mismatch / relaunch (PID) / unknown-ref; ocr+type refuses.
  Pure plan hermetically tested (799 total). 39th MCP tool (`act_ref`). Live-verified:
  the CDP capstone (`see` → `act @ref` VERIFIED by navigation, then stale-refuse) and a
  real isolated Cursor (`web key cmd+shift+l` opened the Agents panel, `see` surfaced the
  renderer, `act` honestly refused on occlusion). Honesty review PASS.

**Feature A: COMPLETE (A1 + A2 + A3 shipped).** A brain now drives any Mac app in two
calls — `see <app>` (one fused eye: AX + CDP + OCR, ranked + `@ref`-stamped) then
`act "@ref"` (auto-picked hand, verify-or-refuse) — plus `web key` to fire keybindings
no other eye/hand can reach. The honesty contract held throughout (navigation-verified,
occlusion-refused, stale-refused, dispatched-unverified — never a fake success).

**Post-A follow-ups shipped (all on `feat/drive-any-app`, PR #13):**
- **#5 ✅ (0.8.12)** — `type`/`set-value` honor `--role`/`--text`/`--nth` on the MCP surface.
- **#6 ✅ (0.8.13)** — `web click` earns VERIFIED on in-page (non-navigating) toggles via a
  post-click DOM state read-back (nav still wins; an unstable read never fabricates).
- **A3-gap ✅ (0.8.14)** — `act "@ref"` pins CDP reattach to the exact renderer `see` read
  (`SeeSnapshot.cdpTargetId` + `CDPTargetPick.id`), so non-default-page refs are actionable.
- **PR review (0.8.15)** — CodeRabbit honesty/correctness fixes: bare `--type` refuses,
  cdp-ref-without-port refuses, ambiguous `--target` substring refuses, `see` settle no
  longer blocks the MainActor.
- **shadow/iframe pierce ✅ (0.8.15)** — `see`/`web read`/`web click`/`fill` descend into
  OPEN shadow roots + SAME-ORIGIN iframes, so a control in a web component (Cursor's
  shadow-root composer) is surfaced AND its `@eN` reattaches. Iframe targets are surfaced
  for reading but `web click` REFUSES them (uncorrected cross-frame click geometry —
  honesty fix from the review). Closes the Cursor-composer capstone gap (shadow half). 827 tests.
- **#1 closed** (Vision/OCR shipped + folded into `see`).

- **#3 ✅ (0.8.16)** — `replay --report-json/--report-junit` emits a CI pass-fail report
  (JSON + JUnit XML) over the existing honest per-step verdicts; `refused`→`<failure>`,
  `dispatched`→pass+note, `skipped` accounted, exit mirrors the policy. 833 tests.

**Open backlog:** #4 (packaging/notarization — blocked on an Apple Developer signing
identity), #2 (always-on daemon + AXObserver — deferred, needs a design pass).
- **Dock launch-witness — evaluated, DEFERRED.** A worktree agent built an honest,
  hermetically-tested launch-witness (poll `apps()` after a Dock press → promote to VERIFIED
  on a fresh launch/activation). Live-verify rejected it: AXPress on a Dock tile doesn't
  observably *foreground* an already-running app (so activation is never witnessed), and
  `NSWorkspace.runningApplications` registers a cold launch too slowly to catch within a
  sane deadline (System Settings missed even at 6s) — while the poll adds latency to every
  Dock click. Revive only with an EVENT-based signal (`NSWorkspace` launch/activate
  notifications — instant, no poll) instead of polling. Honest as-built; just not worth it.
- **OCR window-id robustness ✅ (0.8.17)** — `ocr`/`shot` fall back to PID-matched window
  selection when the AX→CGWindowID bridge fails (no more `could not resolve a CGWindowID`).
  NB: a separate Screen-Recording capture-grant issue on the rebuilt CLI binary (`Failed to
  start stream…`, affects `shot` too) blocked a full end-to-end OCR demo — needs the binary
  re-granted Screen Recording in System Settings to confirm the OCR eye live.
- **iframe read-coords ✅ (0.8.19)** — same-origin iframe rects now translate to TOP-LEVEL
  coords (`ghFrameOffset` walks the `frameElement` chain; cross-origin throws → walk stops),
  so `web read`/`see`/`web find` report + rank an iframe control at its real on-screen
  position. **Click-enable stays deferred (deliberate):** `web click` on an iframe target
  still REFUSES (`iframeClickUnsupported`) — the occlusion hit-test runs inside the iframe's
  own document and can't see a top-document overlay, so a translated click isn't PROVABLY
  safe; an honest refuse beats a click at unprovable-occlusion geometry. Remaining deferred
  piece: making iframe `@ref`s CLICKABLE (needs a provably-safe cross-frame occlusion test).
- **digest ARIA/contenteditable ✅ (0.8.19)** · **`act "@ref"` AX identity-pin ✅ (0.8.19)** ·
  **`act "@ref"` non-actionable refuse ✅ (0.8.19)** — see CHANGELOG 0.8.19.
- ~~Tiny: `see --in <css>` honoring `--target`.~~ ✅ shipped — `see --in <css>` scopes
  the CDP eye to a container and COMPOSES with `--target`: the scope reads off the
  `--target`-picked renderer, a `--target` no-match skips the CDP eye (note) rather
  than silently scoping the default, and a no-match container REFUSES. Parse pulled
  into a pure, hermetically-tested `SeeArgs`.

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
