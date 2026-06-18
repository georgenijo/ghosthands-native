# Changelog

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
