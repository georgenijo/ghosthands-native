# Changelog

## 0.8.9-m4 — 2026-06-19 — `web key` + `--target`: fire app keybindings over CDP (feature A, slice A1)

**Added — `web key "<chord>" <browser> [--debug-port N] [--target <n|title>]`: dispatch a
real key/chord over CDP `Input.dispatchKeyEvent` so an app KEYBINDING/accelerator fires.**
The fix for the Electron gap the Cursor walkthrough exposed — driving a keybinding-only
command (e.g. Cursor's ⇧⌘L agent panel) was impossible: AX can't reach it and a `.value`
set is a no-op. `web key` injects the chord at the renderer the way a real keypress does,
so a web-app/Electron command bound to a chord triggers. Modifiers `cmd/shift/alt/ctrl` +
any base key (letter / digit / `return|tab|escape|space|delete|arrows`). **Honesty:** a
keystroke has NO in-page observable, so `web key` is ALWAYS reported dispatched-unverified
(like the native `key` verb / `window raise`) — never a faked "it fired"; a bad chord
(`unknownKey`/`badKeySpec`) REFUSES *before* any browser/socket is touched.

**Added — `--target <n|title>` on the CDP web verbs (read/click/fill/type/select/html/eval/key):
pick WHICH page/renderer to drive.** Multi-window Electron lists several page targets and
the web verbs hit the FIRST only; `--target` selects a specific one by 1-based index (among
debuggable pages) or a title/url substring. Default (omitted) is the first debuggable page,
unchanged — every existing call site behaves identically. A `--target` that matches nothing
REFUSES (`cdpTargetNotFound`, lists the real pages) rather than drive an arbitrary renderer.

CLI + the 37th MCP tool (`web_key`) + `target` on the CDP tools' input schema. The pure
chord→CDP-fields parse (`CDPKeySpec`: DOM `key`/`code` + Windows VK + the CDP modifier
bitfield Alt=1|Ctrl=2|Meta=4|Shift=8, shift-uppercasing a letter's `key`) and the pure page
chooser (`CDPTargetPick`: index/substring, skips non-debuggable targets, refuse-on-no-match)
are hermetically tested (768 total, +24).

**Live-verified — safe + headed, George's real Brave untouched (isolated throwaway via `web
open --headed`):** a page with a `keydown` handler recording `(meta?cmd+)(shift?shift+)key`
received `web key "cmd+shift+l"` as exactly **`cmd+shift+L`** (the ⇧⌘L mechanism Cursor's
agent panel needs), `cmd+l` as `cmd+l` (lowercase, no shift); `web read --target 1` read the
page, `--target 9` and `--target nonsuch` REFUSED (exit 1, listing the real page); `frobnicate`
and `hyper+l` REFUSED before touching the browser; `web close` removed the throwaway with zero
leftovers. Adversarial honesty review: **PASS** (no over-claim, no wrong-target, no
behavior change when `--target` is absent). Version 0.8.8-m4 → 0.8.9-m4.

## 0.8.8-m4 — 2026-06-19 — Vision/OCR: the universal fallback eye (drive ANY app)

**Added — `ocr` + `ocr-click`: locate + act on surfaces with no AX and no DOM** (a
canvas, a game, a remote screen, a web view with no debug port). Closes the deferred
vision/OCR fork (issue #1) and completes the locator ladder: **AX → CDP → Vision.**
- **`ocr <app>`** — screenshot the front window (ScreenCaptureKit) and run Apple
  **Vision** text recognition, returning every recognized line + its on-screen rect.
  Pure read; needs Screen Recording. A *system* framework — no new SwiftPM dependency.
- **`ocr-click "<text>" <app>`** — OCR, match the phrase (exact-beats-substring), and
  click its center via the **visible HID** path (cursor moves — the labelled
  exception), verified by the screenshot-diff `click-at` already enforces. REFUSES
  when no line matches (never clicks a guessed point — OCR is the fuzziest tier) or
  when >1 match with no exact hit.

CLI + 36th MCP tool (`ocr`, the read eye; `ocr-click` is CLI like the other pixel
verbs). Pure coordinate flip (Vision normalized/bottom-left → screen/top-left) and
the matcher are hermetically tested (744 total, +6).

**Live-verified — all three "drive any app" features composing:** `ocr Cursor` read
20 text regions with coords off Cursor's web-rendered welcome screen (where AX saw no
inputs), then `GHOSTHANDS_GLIDE=1 ocr-click "whoop-dashboard" Cursor` **found** the
text via Vision, **glided** the real cursor to (1131,783), clicked, and **VERIFIED**
by pixel-diff (32.6% changed) — opening the project. Step 3 of 3 done (glide →
Electron-CDP → **Vision/OCR**). Version 0.8.7-m4 → 0.8.8-m4.

## 0.8.7-m4 — 2026-06-19 — Electron-CDP: `web type` for custom editors

**Added — `web type "<@eN|selector>" "<text>" [--submit]`: type via CDP
`Input.insertText`.** The fix for the boundary the Cursor walkthrough exposed —
`web fill` sets `.value`, a no-op on a **contenteditable / custom editor** (Cursor's
agent box, Lexical/ProseMirror, Monaco). `web type` focuses the element and injects
text the way a real keypress would (the primitive Playwright/Puppeteer use), so those
editors accept it; `--submit` then dispatches a real Enter via
`Input.dispatchKeyEvent`. Verified by reading the element's text back (`.value` or
innerText); the send half is honestly reported "Enter dispatched (send unverified)".
CLI + 35th MCP tool (`web_type`). Pure verdict + focus/read-back expressions
hermetically tested (738 total, +3).

**This makes Electron apps drivable.** An Electron app (Cursor, VS Code, Slack,
Discord) launched with `--remote-debugging-port=N` is just Chromium — the existing
web tier attaches and drives its DOM. **Live-verified:** `web read Cursor
--debug-port 9333` read Cursor's real renderer DOM (27 refs + frames) where AX saw
nothing, and `web type` earned a VERIFIED read-back on a live page. (The full
"send a prompt to Cursor's agent" needs one more orchestration step — reliably
*opening* the agent panel — which is UI-specific, not a `web type` limitation.)

Step 2 of 3 toward "drive any app" (glide → **Electron-CDP** → Vision/OCR). Version
0.8.6-m4 → 0.8.7-m4.

## 0.8.6-m4 — 2026-06-19 — "fake mouse" glide (visible cursor travel)

**Added — `GHOSTHANDS_GLIDE=1`: ease the real cursor to the target before a visible
click.** In `.visible` HID mode (`click-at`/`drag --visible`), instead of warping the
cursor straight to the point, glide it there over a smoothstep-eased path (~30
samples × ~9ms ≈ 270ms) computed from the gap between the current cursor position and
the target — the "calculate the distance and move there" idea, watchable. Off by
default (the visible path stays fast) and scoped to the visible HID tier only — it
never touches the invisible AX path. `PixelPath.glide` (the eased geometry: lands
exactly on target, smoothstep-symmetric, monotonic) is pure + hermetically tested
(735 total, +4). Step 1 of 3 toward "drive any app" (glide → Electron-CDP →
Vision/OCR). Version 0.8.5-m4 → 0.8.6-m4.

## 0.8.5-m4 — 2026-06-19 — highlight on EVERY act verb

**Extended `GHOSTHANDS_HIGHLIGHT=1` from `click` to every native act verb.** Now the
overlay box flashes wherever ghosthands acts: `click`, `type`, `set-value`,
`doubleclick`, `act`, `focus`, `right-click`, `menu` (each item as it descends — the
boxes walk down the menu), `scroll` (the scroll area), and `drag` (source then
destination). Done via a shared `Highlight.flashIfEnabled(element)` called right
before each actuation; gated by the env var, so off = zero cost everywhere. Verbs
with no target element (`key`, `navigate`) and the CDP web verbs (page coords, not
screen) are intentionally not wired. Live-verified: a highlighted Calculator
sequence (keypad clicks + a `View > Basic` menu walk) flashed a box on every step
with no cursor move / focus steal. Version 0.8.4-m4 → 0.8.5-m4.

## 0.8.4-m4 — 2026-06-19 — see-where-it-acts (opt-in visual overlay)

**Added — `GHOSTHANDS_HIGHLIGHT=1`: a visual overlay so a human can SEE where
ghosthands acts.** When set, `click` flashes a red highlight box at the target
control's on-screen frame (read from AX) just before pressing it. The paradox it
resolves: ghosthands never moves the mouse (it acts through the AX tree), so there's
no pointer to film — instead we draw a transparent, **click-through, non-activating**
overlay panel (`.screenSaver` level, `ignoresMouseEvents`, `orderFrontRegardless`)
at the element's frame, pulse it, and fade. **No cursor move, no focus steal** — the
invisibility contract is fully intact (verified live: the frontmost app was unchanged
across a flash). Observability only: it shows where the AX target *is*, never a fake
pointer, and a refuse flashes nothing (the box fires only right before a real press).
Off by default → no AppKit window is ever created, zero cost.

Pure pieces (the AX→Cocoa coordinate flip + the env gate) are hermetically tested
(731 total, +3); the panel draw is live-only. Live-verified flashing on the Cursor
Dock tile and on a toolbar button. Version 0.8.3-m4 → 0.8.4-m4.

## 0.8.3-m4 — 2026-06-19 — the app-level eye + open-an-app-by-its-Dock-icon

Two additions that let a brain do the most natural thing — *"open Cursor"* → see
what's running, then click the Dock icon — entirely through ghosthands.

**Added — `apps`: list running GUI apps.** Name, bundle id, pid, and a `[frontmost]`
marker, sorted by name; faceless daemons / XPC services excluded
(`activationPolicy == .regular`) so the list matches the Dock + Cmd-Tab, not the
process table. Pure read (no AX walk, no focus steal). CLI + 34th MCP tool + `--json`
(a `{count, apps:[…]}` envelope). The app-level **eye**: answer "what's open?" before
deciding to open or drive something.

**Fixed — `click "<App>" Dock` now opens/activates an app by its Dock icon.** A Dock
tile is an `AXDockItem`, which advertises AXPress (pressing it launches/activates the
app — the same thing a human does clicking the Dock) but was missing from the
control-role allowlist, so `find` saw it while `click` refused it. Added `AXDockItem`
to `Finder.controlRoles`. Now `click "Cursor" Dock` launches Cursor. Honest verdict:
**dispatched-unverified** (a Dock press has no in-element observable) — the launch is
confirmed by a follow-up `apps` read, the brain verifying through the eye rather than
the tool asserting. (A launch-witnessed VERIFIED is possible future polish.)

**Architecture note (why this matters):** ghosthands is **hands + eyes, no model**.
The "instinct" to *check the Dock → find the icon → click it* is the **brain's** job
(the agent/LLM driving the verbs), never the tool's. These two additions give that
brain the eye (`apps`) and the hand (`click … Dock`) for app-level control; the
planning stays where it belongs — outside the tool. Live-verified: `apps` showed
Cursor absent, `click "Cursor" Dock` launched it, `apps` then showed it running.
728 hermetic tests (+4). Version 0.8.2-m4 → 0.8.3-m4.

## 0.8.2-m4 — 2026-06-19 — menu bar (a DEFERRED row goes green)

**Added — `menu "<A > B > C>" <app>`: drive an app's regular menu bar.** Resolves a
` > `-separated path through the Accessibility tree — `AXMenuBar` → `AXMenuBarItem`
→ AXPress to open → descend each `AXMenu` → AXPress the leaf — with **no cursor, no
focus steal**. CLI + 33rd MCP tool (`menu`) + `--json` envelope.

This flips a capability-matrix row that was marked **DEFERRED**. The deferral was
about **MenuBarExtra / Control Center** (status-bar items whose AXPress is a no-op);
a **regular app menu** (File/Edit/View/…) is fully AX-drivable, which a live probe on
Cursor confirmed. The matrix now splits the row: regular menus ✅ (this verb),
Control Center/MenuBarExtra still DEFERRED.

**Honesty:** a menu action's effect (open a folder, run a command) is downstream and
app-specific — there is no in-AX observable on the menu itself — so `menu` is always
**dispatched-unverified** (AXPress accepted at each step), NEVER a fabricated success
(mirrors `key` / `act raise`). What it DOES enforce: each segment must resolve to
**exactly one** item (exact-beats-substring; the ellipsis menus append is matched
naturally), and a segment matching **none or >1** item REFUSES — listing the real
items at that level — closing any menu it opened so a refuse never leaves the app's
menu hanging. A non-final segment with no submenu also REFUSES (path walked past a
leaf). Pure parsing + matching are hermetically tested (724 total, +13).

**Live-verified** end-to-end on Cursor, ghosthands-only: `menu "File > Open Recent >
~/Documents/code/murmur-app" Cursor` opened the project (read back via `windows` as
`"… — murmur-app"`), and `menu "File > Frobnicate" Cursor` refused (exit 1) listing
all 20 real File-menu items.

## 0.8.1-m4 — 2026-06-19 — web-parity level-up

A fresh agent-browser-vs-ghosthands head-to-head (full 11-task battery, both driven
directly) re-confirmed the win on capability + honesty + native reach, and surfaced
two concrete web-driving gaps + one stale doc claim. All three closed; 711 hermetic
tests (+9), each fix live-verified on the exact case that exposed it.

**Fixed**
- **`web read` was hiding fillable text inputs.** A render-side filter dropped any
  digest row with no name, no value, and no form-state — which silently killed a
  bare or `<label>`-wrapped text input that reads empty pre-fill (httpbin's
  `custname`/`custtel`/`custemail`). The element *was* ref-stamped and fully
  fillable; it just never appeared in `web read`, forcing a hand-written CSS
  selector. Now any **ref-stamped (interactive) row is KEPT** even when empty — a
  ref means actionable, never noise; a ref-less empty text/heading node still drops.
  *Live-verified:* httpbin `web read` went 8 → **13 elements**, every field present.
- **`web read` now derives a real accessible NAME for label-wrapped controls.** The
  name was `aria-label || innerText` only, so a `<label>Customer name: <input></label>`
  read blank. Added `accName()` — `aria-label` → `<label for=id>` → wrapping
  `<label>` → innerText → `placeholder` → `name` attr (all REAL sources, never
  fabricated; every lookup guarded). httpbin inputs now read `"Customer name:"`,
  radios/checkboxes read `"Small"`/`"Bacon"` instead of blank — matching a screen
  reader and agent-browser's snapshot, so the whole form is addressable by `@eN`.

**Added**
- **`web select "<@eN|selector>" "<value>" [browser]`** — drive a `<select>`
  dropdown, the web analogue of `set-value`. Matches an option by its **value OR its
  visible text**, sets it, fires input+change, and **reads the chosen option back**:
  read-back == request → **VERIFIED**; the set didn't stick → dispatched-unverified;
  the target isn't a `<select>` → **REFUSE** (`notASelect`, names the real role); no
  option matches → **REFUSE** (`optionNotFound`, lists the real options) — never
  leaves the prior selection and claims success. Exposed on the CLI **and** as the
  32nd MCP tool (`web_select`). Closes the last "drop to `web eval` for a dropdown"
  gap. *Live-verified* on the-internet/dropdown: by value (`"2"`→"Option 2"), by
  text (`"Option 1"`), by `@ref`, and both refuse paths (exit 1).

**Docs**
- Corrected the **stale "agent-browser can't play YouTube/DRM" claim** in
  WEB-PARITY.md + STRESS-TEST-0.8.0.md. On the 2026-06-19 re-test (agent-browser
  0.27.0) YouTube **played** (`currentTime` advanced after a user-gesture click;
  bare `.play()` is blocked by autoplay policy, not codecs). It is no longer a
  ghosthands advantage; the native-app gap is the only durable structural miss.

## 0.8.0-m4 — 2026-06-18 (overnight build)

The big completeness push — a production-grade, honest, invisible computer-use +
UI-testing surface. Every capability-matrix row is now ✅ except the two George
explicitly deferred (menu bar; always-on daemon). Built across ~16 worktree-isolated
implement→review→fix workflows, integrated serially, each honesty-reviewed and
live-verified where the environment allowed. 325 → **657 hermetic tests**.

**Web / DOM (CDP tier — 4 slices, additive beside AX, loopback-only):**
- **`web read --cdp` / `web tabs --cdp`** — connect to an already-open DevTools port
  and read the page (incl. **background tabs** AX can't see); `auto` lens prefers CDP
  when a port is reachable and falls back to AX silently, `--ax` forces AX, forced
  `--cdp` on a closed port refuses (`cdpPortClosed`). Hand-rolled CDP over
  `URLSessionWebSocketTask` (no new dep): pure `/json/list` decode + loopback guard +
  id-match/event-skip classifier + a deadline-bounded session.
- **`web click <selector>` / `web fill <selector> <text>`** — DOM-selector actuation
  with the agent-browser-mined **occlusion "covered-by" refuse** (never click through
  an overlay); click verified by navigation, fill by value read-back.
- **`web html <selector>`** (outerHTML + attributes + computed style) and **`web eval
  <js>`** (a page-side throw surfaces as a refuse, never a fake success).
- **`--relaunch`** — consent-gated isolated relaunch: when a port is closed, launch a
  throwaway instance with an ephemeral port + a fresh temp profile (never the real
  profile), reading the chosen port from the `DevToolsActivePort` sidecar. Default
  (no flag) is the unchanged refuse; never silent.

**Native verbs:** `focus` (+ auto-focus-on-type) · `right-click` (AXShowMenu/pixel,
menu-appeared witness) · `scroll` (AXScrollBar witness) · `drag <from> <to>` (witnessed
by the source moving) · `extract` (AXTable/AXOutline/AXList → TSV rows) · `dialog`
(detect a modal + `--click` a button, witnessed by dismissal).

**Testing + interface:** `wait` (deterministic poll to a hard deadline, no magic
sleeps) · `assert`/`expect` (exists/absent/value/count — PASS 0 / FAIL 1 / refuse 2) ·
locator disambiguators **`--nth` / `--role` / `--text`** (the no-flag refuse-on-ambiguous
is unchanged) · **`--json`** result envelope on *every* verb (stable
`{verb,status,evidence,fields,error}`; status mirrors the human verdict, exit codes
identical, default output unchanged) · **full MCP surface** (8 → **31 tools**, results
reuse the JSON envelope, refuse → `isError`) · `clipboard read/write` · **opt-in failure
artifacts** (`GHOSTHANDS_ARTIFACTS=<dir>` → screenshot + JSONL log on a refuse, never
changes an exit code).

**Fixed — a latent cyclic-AX-tree bug class (since M1), three parts, caught only by
live-verify (hermetic trees don't cycle):**
- **SIGSEGV** — AXorcist's `searchElements` honors `maxDepth` only when > 0; left at 0
  (unbounded), a cyclic AX subtree (macOS 26 exposes them) recursed until the stack
  overflowed (exit 139) on the not-found walk of *every* resolve verb. Bounded to 100.
- **Hang** — even depth-bounded, AXorcist's search has no visited-set, so a
  high-branching cycle re-walks `branching^depth` → an effective hang (`extract` hung;
  `find` measured ~50 s). Added **`Finder.descendants`** (depth cap + `Set<Element>`
  visited, the Snapshot/Web pattern) and routed the **shared** resolve path
  (`candidateMatches` / `presenceMatches` / `Find`) + extract/scroll through it, using
  AXorcist's own per-node `matches()` so the candidate set is unchanged. **`find` 50 s
  → 0.8 s.** This also satisfies the bounded/degraded-AX guard goal.

## 0.7.0-m4 — 2026-06-18

Browser-task completeness — the three verbs that close the gaps a live
Wikipedia-search demo exposed: **go anywhere**, **press keys**, **know where
things are**. Built in parallel (isolated worktrees), each honesty-reviewed PASS.

**Added**
- **`navigate <url> [browser]`** — load a URL in a browser and prove the page
  changed. Actuates via `open -a` (the `Install` `Process` idiom), then wakes +
  reads the browser's `AXWebArea` document URL/title back: **verified** only when
  the landed host (and path when requested) matches the request; **dispatched-
  unverified** when the load issued but can't be confirmed (AXWebArea absent /
  still loading / redirect); **refuse** on a malformed URL or unresolved browser.
  `open`'s exit status is *structurally excluded* from the verdict — only the
  read-back proves it. Default browser = first running Chromium (auto-pick
  reported). v1 uses `open`; the omnibox-driven version (type URL + `key` Enter)
  is a future upgrade now that `key` exists.
- **`key <spec> [app] [--visible]`** — send a keystroke or chord: `return`/`enter`,
  `tab`, `escape`, `space`, arrows, letters, digits, with `cmd`/`shift`/`alt`/`ctrl`
  modifiers (`cmd+s`). Invisible-first: default posts a key-down/up `CGEvent` pair
  via `CGEventPostToPid` (cursor-less, background best-effort); `--visible` focuses
  the app + posts via the HID tap (the labelled exception, mirrors pixel
  `--visible` — moves focus, not invisible). A keystroke has **no built-in
  observable**, so the verdict is **always dispatched-unverified**, never faked; an
  unknown key / bad spec **refuses** before any post. The name→keycode + modifier→
  flags tables + chord parse are pure and hermetically tested.
- **`web read` now emits each interactive control's on-screen frame** `@(x,y w×h)`,
  read from AX (`Element.frame()` = `AXPosition` + `AXSize`) — so a web control can
  be pixel-targeted *exactly* instead of eyeballed off a screenshot. A control
  whose frame AX can't read is marked `frame:?`, **never a fabricated box**; static
  text omits coordinates (not a pixel target). `ElementFacts` gained an optional
  `frame` captured in `Finder.facts(of:)` (snapshot text unchanged).

**Live-verified end-to-end on a backgrounded Brave — the full task, ghosthands-only:**
`navigate` → `verified: landed https://en.wikipedia.org/...`; `web read` →
`AXTextField "Search Wikipedia" @(3360,161 405×32)`, `AXButton "Search"
@(3763,161 72×32)` (exact frames); `type "Barack Obama"` → verified `"" → "Barack
Obama"`; a `pixel --visible` click on the field's exact frame focused it; `key
--visible return` submitted; a final `web read` landed on `AXHeading "Barack
Obama"`. **Honest finding (recorded, not hidden):** an AX-typed field is not
*focused*, so a bare invisible `key return` does not submit — it honestly reported
`dispatched; effect unverified`, and the page did not change, until a focus-click
preceded it. A `focus` helper / auto-focus-on-type is the next small refinement.

**Tests:** 325 hermetic total (+45: 18 navigate, 21 key, 6 web-frames). Each tier
passed an adversarial honesty review; merged on `main` (build + 325 green, additive
`Errors.swift`/`CLI.swift` changes auto-merged clean) and live-verified before push.

**Built on** AXorcist (MIT). See ATTRIBUTION.md.

## 0.6.0-m4 — 2026-06-18

M4 hard surfaces, continued: window identity + management, multi-monitor aware,
AX-only, every mutation proved by reading the frame back.

**Added**
- **`windows <app>`** — list each of an app's windows with a stable identity:
  CGWindowID (via the same `_AXUIElementGetWindow` shim the effect-witness
  already uses to pin a window), title, frame, the display it sits on (frame
  center mapped to a `CGDisplayBounds` top-left rect), and main / focused /
  minimized flags. Pure read — no focus steal. An unreadable AX window-list
  refuses *distinctly* from a genuinely windowless app (never mislabels an AX
  failure as "no windows").
- **`window move <x> <y> <app> [--window <id|title>]`** and
  **`window resize <w> <h> <app> [--window <id|title>]`** — set `AXPosition` /
  `AXSize` through AXorcist's correctly-typed `AXValue` setters (the generic
  `setValue` does *not* bridge `CGPoint`/`CGSize`), then **re-read the frame and
  verify**: VERIFIED only when the read-back lands within 2px of target;
  **OS-clamped** (min-size, off-screen guard, full-screen ignores the set)
  reports the *actual* landed frame as honest dispatched-unverified; an
  AX-accepted-but-unchanged set is dispatched-unverified. The AX dispatch result
  is never used as proof — the read-back is the only truth.
- **`window raise <app> [--window <id|title>]`** — raw `AXRaise` (deliberately
  *not* `focusWindow`/`showWindow`, which would activate the app and steal
  focus). A stacking change with no AX read-back, so it is **always**
  dispatched-unverified and explicitly never claims activation; a rejected raise
  refuses.
- Ambiguity (>1 window with no/over-matching `--window` selector) **refuses**
  rather than mutating an arbitrary window — mirrors `click`'s ambiguity gate.

*Live-verified* on a backgrounded TextEdit, proven by ghosthands' own read-back
(not an external tool): `move` reported `verified: (2869,103 673×439) →
(3000,300 673×439)` (position changed, size untouched); `resize` reported
`verified: (3000,300 673×439) → (3000,300 800×550)` (size changed, position
untouched); a follow-up `windows` listing confirmed the final frame.

**Known limitations (surfaced, not hidden)**
- `window raise` z-order has no reliable AX read-back → always dispatched-
  unverified (honest, never faked). OS position/size **clamping** is reported
  with the real landed frame, never as a false verified. Off-screen / Space-
  shifted windows map to "off-screen"; a nil CGWindowID reads as `id=?`, never
  fabricated. Clamped/dispatched share exit 0 with verified (honesty is in the
  text, matching the act/pixel tier convention — only refuse is nonzero). Window
  verbs are not yet wired into record/replay or the MCP tool surface (follow-up).

**Tests:** 280 hermetic total (+34 window). Honesty review PASS; merged on `main`
(build + 280 green, additive `Errors.swift` conflict with `install` resolved
keep-both); the window verbs were live-verified before push.

**Built on** AXorcist (MIT). See ATTRIBUTION.md.

## 0.5.0-m4 — 2026-06-18

M4 hard surfaces. New verbs that reach past the AX action set, each honest about
what it can prove.

**Added**
- **`install <dmg> [--force] [--dest <dir>]`** — the "install an app" surface,
  cursor-less. Mounts the DMG (`hdiutil attach -nobrowse -noverify -plist`),
  finds the single top-level `.app`, copies it with `cp -R` (not a GUI drag) to
  the destination (default `/Applications`), **always detaches** the mount (a
  crash-safe `defer`), and **verifies** the installed bundle is really present
  with a parseable `Info.plist` `CFBundleIdentifier` — never just "cp returned
  0". Honest verdicts: **verified** (bundle present + identifier) / **dispatched-
  unverified** (copied but unconfirmable — never the word "installed") / **refuse**
  (exit 1) on no DMG, mount failure, zero or >1 `.app` (never guesses which),
  destination already exists without `--force` (never clobbers an installed
  app), or copy failure. Four pure decisions (mount-point parse, `.app` choice,
  overwrite gate, verify decision) are unit-tested; the live path drives them
  with real values. First subprocess in the codebase — plain `Foundation.Process`,
  no new deps. *Live-verified* with a throwaway DMG into a temp dest (never
  touched real `/Applications`): install → `verified: CFBundleIdentifier
  com.ghosthands.testapp present`; a second install without `--force` → honest
  refuse (exit 1, "refusing to overwrite … pass --force"); with `--force` →
  verified again; an independent `PlistBuddy` read confirmed the identifier on
  disk; no volume left mounted (clean detach across the refuse path too).
  A review pass caught and fixed a real robustness bug pre-merge: the detach
  `defer` called `waitUntilExit()` unconditionally after a `try?`'d launch, which
  would `SIGABRT` (and leak the mount) if `hdiutil` ever failed to launch on
  detach — now the wait is guarded behind a successful `run()`.

**Known limitations (surfaced, not hidden)**
- `install`'s scope of "verified" is **presence + a parseable
  `CFBundleIdentifier` only** — Gatekeeper / quarantine / notarization, code-
  signature validity, and first-launch TCC are out of scope (presence, not
  trust). The live subprocess pipeline (real mount/detach/`cp -R`/`--force`
  remove) is exercised by the live-verify above but is not in the hermetic suite
  (rails forbid mounting a real DMG or writing a real install dir in unit tests);
  the four pure decisions carry the 21 hermetic tests.

**Tests:** 246 hermetic total (+21 install). Honesty review PASS; merged on
`main` (build + 246 green); `install` live-verified before push.

**Built on** AXorcist (MIT). See ATTRIBUTION.md.

## 0.4.1-m4 — 2026-06-18

Two honest-but-limited tiers from 0.4.0 hardened. The web read tier now works on
Chromium (the limitation that mattered most), and the pixel tier gains a real
actuation path. Built in parallel in isolated worktrees, each through a
Map→Implement→Review→Fix workflow; both reviewed PASS for honesty before merge.

**Fixed / improved**
- **web read now works on Chromium (Brave / Chrome).** Chromium builds its web
  accessibility tree lazily, so 0.4.0 honestly reported "browser chrome only;
  nothing to read" on Brave. We now set `AXManualAccessibility = true` on the
  browser's AX application element before walking (in both `web read` and
  `web tabs`, and on the fresh element inside each settle/retry, since a new
  `AXUIElement` doesn't inherit the flag). The tree wakes; the page becomes
  readable. AX-only — no CDP/DOM path. *Live-verified* on a backgrounded Brave:
  `web read` returned the real page tree (163 elements off a YouTube tab, exit 0,
  where 0.4.0 was inert). The honesty floor is structurally unchanged — the wake
  is best-effort (returns Void, the `setValue` Bool is ignored, it injects no
  nodes); `hasWebArea` and the `tabsNotExposed` refuse still derive from the real
  post-wake tree, so a failed wake still reads empty / refuses and can never
  fabricate a page. (Reviewer caught and we dropped an `AXEnhancedUserInterface`
  set — it mutates foreign AppKit/Electron apps' UI mode on a *read*;
  `AXManualAccessibility` is the narrow Chromium-specific opt-in.)
- **pixel `--visible` HID mode — `click-at` / `drag` can now actually actuate.**
  `CGEventPostToPid` does not actuate a backgrounded window (0.4.0 live-tested:
  Calculator ignored it, honestly unverified). The new, explicitly-labelled
  `--visible` mode posts a real HID click via `CGEvent.post(tap: .cghidEventTap)`:
  save cursor → `CGWarpMouseCursorPosition` → down/interpolated-moves/up → warp
  back + `CGAssociateMouseAndMouseCursorPosition`. The default stays the
  cursor-less `CGEventPostToPid` best-effort path, unchanged.

**Known limitations (surfaced, not hidden)**
- **web tabs is still inert where the browser exposes no `AXTabGroup`.**
  *Live-tested* on Brave: even after the wake, `web tabs` found no tab strip on
  the AX tree and honestly **refused** (exit 1, "refusing to guess a tab list").
  The wake exposes the *page* (AXWebArea), not necessarily the native tab strip;
  background/inactive tabs may also not populate. A CDP/DOM path is the real fix
  for tabs — still future, still AX-only here.
- **pixel `--visible` is the labelled invisibility exception, and the OS wall is
  real.** It moves/flickers the cursor and may foreground / steal focus —
  `--help`, the `PixelMode` doc, and the verdict label all say so plainly; it is
  NOT invisible. macOS routes the HID mouse to the SCREEN-frontmost window under
  the point, so it cannot actuate a truly background window without raising it.
  A review-flagged subtlety is disclosed in the label/help/doc: the verify-diff
  measures the *target* AX-frontmost window while the HID lands on the
  *screen-frontmost* window under the point, so on overlap the verdict reflects
  the target window's repaint — it can only ever **under**-claim, never fake a
  VERIFIED. The runtime HID path is not exercised in the hermetic suite (rails
  forbid posting real HID events in tests); only the pure logic (flag parse, mode
  selection, drag interpolation, verdict mapping) is unit-tested. *Live-verified*
  on a foregrounded TextEdit: a `--visible` drag across two text lines selected
  them and honestly reported **verified** (39.1% of the region changed); an
  immediate identical re-drag found the text already selected, produced no new
  pixel change, and honestly reported **dispatched-unverified** — the same
  command, no false success when the world didn't move; and the cursor was saved
  and restored to its exact prior point (1133,930 → 1133,930).

**Tests:** 225 hermetic total (+14: 5 web wake, 9 pixel). Both tiers passed an
adversarial honesty review inside their workflow; merged on `main` (build + 225
tests green); the web wake was live-verified on a backgrounded Brave before push.

**Built on** AXorcist (MIT). See ATTRIBUTION.md.

## 0.4.0-m4 — 2026-06-18

Four tiers built in parallel (isolated worktrees, merged into one tree): a
pluggable MCP server, record/replay, pixel actuation, and a web read tier. Two
land fully; two are honest-but-limited and labelled as such — never sold as more
than they are.

**Added**
- **MCP server** (`ghosthands-mcp`) — a stdio JSON-RPC 2.0 server exposing the
  eight verbs (`click/type/set_value/doubleclick/act/snapshot/find/shot`) as MCP
  tools, so **any agent — a local model, Claude, a phone agent — can plug in and
  drive the Mac**. `initialize` / `tools/list` / `tools/call`; outcomes map
  faithfully (verified vs dispatched-unverified carried through; a thrown
  `GhostHandsError` becomes an `isError` result with the honest message — the
  wrapper never collapses a refuse or an unverified into success). *Live-verified*
  over stdio: `tools/call click` on a missing element returns `isError` with
  "no element named …", `find` returns a real result.
- **record / replay** (`ghosthands record` / `replay`) — a deterministic JSON
  flow of verb steps. `replay` runs each step via the real verbs with an honest
  per-step verdict (verified / dispatched-unverified / REFUSED), **stops on the
  first refuse** (the world diverged) unless `--keep-going`, and exits non-zero if
  any step refused; unverified steps are counted, never passed off as success.
  `record` executes a verb and appends it only if it didn't refuse. *Live-verified*
  on a backgrounded Calculator: record→replay of a digit press, each step
  `verified` by the display witness, honest summary.
- **pixel `click-at` / `drag`** — coordinate actuation for no-AX surfaces, posted
  to the target pid (`CGEventPostToPid`), verified by a before/after
  **screenshot-diff** of the click region (verified only on an observed pixel
  change; else dispatched-unverified; out-of-window point → refuse).
- **web read tier** (`ghosthands web read` / `tabs`) — a chrome-stripped
  web-scoped digest of a browser's `AXWebArea` page subtree + tab list, AX-only,
  reading only what's on the tree (never fabricated).

**Known limitations (surfaced, not hidden)**
- **pixel actuation does not reach a *backgrounded* window.** `CGEventPostToPid`
  was *live-tested* on a backgrounded Calculator: the event dispatched but the app
  did not process it (display unchanged), and `click-at` honestly reported
  "no observable pixel change (effect unverified)" — it never faked the click. So
  the pixel tier is useful for the **foreground / focused** no-AX surface, and is
  honest (not a false success) when a background poke doesn't take. Reliable
  background pixel actuation would need the visible HID-tap path (breaks
  invisibility) — deferred.
- **web tier is inert on Chromium.** *Live-tested* on Brave: no `AXWebArea` /
  `AXTabGroup` is exposed on the AX tree (Chrome/Brave don't publish web a11y by
  default), so `web read` honestly reports "browser chrome only; nothing to read"
  and `web tabs` refuses rather than guess. The tier works where the browser
  exposes web AX (Safari, or Chromium with accessibility forced on); a CDP/DOM
  path (as the old Python build used) is the real fix — future work. The digest /
  chrome-strip / tab logic is hermetically tested on fabricated trees.

**Tests:** 211 hermetic total (+91 across the four tiers); each tier passed an
adversarial honesty review inside its workflow. The integration was merged on
`main` (build + 211 tests green) and the four verbs above were live-verified /
honestly-bounded as noted before push.

**Built on** AXorcist (MIT). See ATTRIBUTION.md.

## 0.3.0-m3 — 2026-06-18

More actions. Four mutating verbs on one shared honesty core — every one proves
its effect by reading the world back, or says it couldn't.

**Added**
- `ghosthands type "<text>" "<field>" <app>` — set a text-entry control's value
  via AX (cursor-less, no synthetic keystrokes), then RE-READ it off a fresh
  tree. **VERIFIED** only when the field reads back as the text (or demonstrably
  changed); a set the AX layer accepts but that does NOT change the value is
  reported **dispatched-unverified** (the no-op trap — never success); a secure
  (password) field is **REFUSED** up front, because an unreadable value can never
  be verified.
- `ghosthands set-value "<value>" "<control>" <app>` — checkbox / switch / radio
  / slider / stepper / popup. The value is type-**coerced** to the control
  (on/off → 1/0, numeric for sliders, string for popups); an uncoercible request
  (e.g. `"banana"` for a slider) **REFUSES** rather than set a wrong value.
  Verified by the same value-read-back, with the M2 sibling-witness fallback for
  opaque controls.
- `ghosthands doubleclick "<name>" <app>` — open a row / cell / file. Prefers the
  `AXOpen` action (the AX double-click equivalent), falls back to `AXPress`,
  REFUSES if the control advertises neither. Verified by read-back / witness.
- `ghosthands act <action> "<name>" <app>` — invoke a named AX action:
  `open | confirm | pick | show-menu | cancel | raise | increment | decrement`.
  The control must **advertise** the action (pre-checked — wrong action REFUSES
  early with the supported list); an unknown friendly name is a usage error
  (exit 2). `increment`/`decrement` are VERIFIED by NUMERIC DIRECTION (a value
  that saturated at a bound is honest dispatched, not a faked success); actions
  with no in-AX observable (`raise`, `show-menu`) land as dispatched-unverified,
  never fabricated.
- **`EffectProbe`** — the M2 effect-witness machinery (window-pinned by
  CGWindowID, settle-twice causation fence, demote-on-2+) extracted into one
  audited place so all mutating verbs (click / type / set-value / doubleclick /
  act) share the SAME false-positive defences instead of re-deriving them. `click`
  was refactored onto it with no behaviour change.
- Pure, hermetically-tested verdict logic: `ValueVerdict` (the no-op-fakes-success
  guard for type/set-value), `DirectionVerdict` (increment/decrement), `ValueCoercion`
  (coerce-or-refuse), `ActionName` (friendly→AX map). 120 hermetic tests total
  (+51), all fabricated facts — no live app driven.

**Fixed**
- **Honest read of text controls.** `AXTextArea` / `AXTextField` values read back
  as `nil` through AXorcist's generic `value()` (its `Any`-typed convert step
  drops a plain CFString). That silently broke verification — a `type` that
  genuinely landed read the field back empty and under-claimed
  dispatched-unverified — and hid field contents from `snapshot` / `find`. Now
  reads fall back to the raw `AXUIElementCopyAttributeValue` (the path a screen
  reader uses) when the typed read is nil; the fallback only fires on nil, so no
  M2 control changes. Caught by live-verify, not the unit tests.
- **Read-back gate matches the resolve gate.** `doubleclick`/`act` re-read the
  control through the SAME candidate gate they resolved it with (`isOpenable` /
  `isSettable`), threaded through `performAndVerify`. A hardcoded narrower gate
  would have made an opened `AXRow` invisible to its own read-back → a false
  "no longer present" VERIFIED. Found by adversarial review; fixed before ship.

**Verified** live against a backgrounded TextEdit (world-checked via an
independent cua read): `type "VERIFIED-LIVE-0618"` reports
`verified: value "…" → "VERIFIED-LIVE-0618"`, the field independently reads back
as exactly that, the app stays `active:false`, and `type` issues no pointer
events (pure AX set-value — the cursor is never touched). The first attempt
honestly reported dispatched-unverified on a control whose value AX would not
hand back — the cardinal-sin guard working before the read-fix made the value
observable. set-value / doubleclick / act share this live-proven core and are
hermetically covered.

**Built on** AXorcist (MIT). See ATTRIBUTION.md.

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
