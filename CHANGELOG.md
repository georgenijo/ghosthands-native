# Changelog

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
  selection, drag interpolation, verdict mapping) is unit-tested.

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
