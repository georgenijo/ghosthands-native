# Real-life stress test — ghosthands 0.8.0-m4 (2026-06-18)

A fresh agent with **zero prior knowledge of this repo** was handed only the operating
manual + a multi-leg task list and told to drive ghosthands against live websites and a
real Mac, timing itself and reporting honestly. The point was to find rough edges, not to
pass.

## Result: 11/11 tasks completed, zero fake successes, zero crashes, zero AX wedges

Every action's verdict was independently cross-checked. **No verb ever claimed a success it
could not prove** — the product thesis held under real load.

| # | Task | Status | Proof |
|---|------|--------|-------|
| 1 | Hacker News top 5 + points/comments | VERIFIED | CDP `web eval` over the live DOM |
| 2 | Wikipedia "Octopus" first sentence + ref count | VERIFIED | 151 ref entries / 305 inline citations |
| 3 | `Special:Random` ×3 | VERIFIED | 3 distinct titles + first lines |
| 4 | DuckDuckGo "tallest mountain in Africa" | VERIFIED | Kilimanjaro, off the top result |
| 5 | HN #1 → top comment | VERIFIED | item 48584135 |
| 6 | BBC News 6 headlines | VERIFIED | 6 card-headline reads |
| 7 | httpbin pizza form fill + submit | VERIFIED end-to-end | submit verified by navigation; echo == input exactly |
| 8 | the-internet dropdown + checkboxes | done | dropdown VERIFIED; checkbox toggles DISPATCHED, read-back confirmed `[true,false]` |
| 9 | HN top 3 → TextEdit numbered list | VERIFIED | `type` read-back + an independent AppleScript doc read |
| 10 | YouTube play first video | VERIFIED | click→nav verified; playback proven by `currentTime` advancing |
| 11 | Google Maps "coffee near me" top 3 | VERIFIED | DOM side-panel feed read (the map canvas was correctly NOT faked) |

`web fill` always returned VERIFIED (read-back). `web click` on non-navigating targets
(radio/checkbox) always returned DISPATCHED-UNVERIFIED — correct, it can only prove
navigation. `type` correctly REFUSED an ambiguous target.

## Timing (the cyclic-AX-tree fix held)

- **Total wall-clock: ~439.6s (~7.3 min).**
- **Inside ghosthands: ~16s** across 40+ read/fill/click calls — nearly all **0.04–0.11s**;
  `type` 0.90s; the 5-window ambiguity refuse 0.38s.
- **Waiting on page/network/poll loops: ~424s** — JS-heavy SPAs (YouTube, Maps), httpbin
  latency, and the agent's conservative poll loops. Not the tool.
- Only one ghosthands call exceeded 3s: the httpbin **submit click at 11.95s** — blocking on
  the POST navigation round-trip, not tool overhead.
- **No AX traversal was slow** — every resolve/read/fill stayed well under 1s, validating the
  shared `Finder.descendants` (depth + visited-set) fix on macOS-26 cyclic trees.

## Findings → tickets

Two real, well-scoped improvements the test earned (filed):

- **#5 — `type` / `set-value` should accept the `--nth` / `--role` / `--text` locator
  disambiguators** that `click` already has. 5 TextEdit windows → 4 matching controls →
  honest REFUSE with no escape hatch. The `LocatorSpec` is already built; just thread it in.
- **#6 — `web click` should verify in-page (non-navigating) clicks by a post-click DOM
  read-back** (`:checked` / value / targeted state diff), so a checkbox/radio toggle can EARN
  VERIFIED instead of under-claiming. The agent-browser-mined "read-back every verb" mechanic.

## Non-issues (environmental, surfaced honestly — NOT tool faults)

- YouTube logged-out cold profile → empty home feed; the agent adapted (searched, played the
  first result) rather than fabricate a "first video".
- Google Maps "near me" is IP-geolocated and the map tiles are a **canvas** (no AX, no DOM);
  the agent read only the DOM side-panel feed and **did not pretend to read the map**.
- One selector mistake (`.titleline a` grabbing a site-bit domain link) was the driving
  agent's, not ghosthands'.

## Bottom line

Fast, honest, never lied. Everything marked DISPATCHED was independently confirmed to have
actually happened; everything marked VERIFIED carried real evidence; ambiguity and
unreadable surfaces were refused, not guessed.

---

# Head-to-head — the same 11 tasks on agent-browser 0.27.0 (native verbs, no JS)

The identical battery was run against the competitor (vercel-labs/agent-browser) to compare.

## Result: 9/11 native, 1 partial, 1 honest fail — both misses STRUCTURAL, not bugs

- **Task 9 (HN → TextEdit):** browser half only — agent-browser **cannot drive a native
  macOS app** (Electron/Chromium only). This is the capability ghosthands has and
  agent-browser structurally lacks.
- **Task 10 (YouTube play):** ~~its bundled Chromium **can't play DRM/H.264 video** ("Something
  went wrong" — missing proprietary codecs/Widevine)~~. **SUPERSEDED (re-test 2026-06-19,
  agent-browser 0.27.0):** YouTube **played** on agent-browser — `currentTime` advanced
  0.83→4.86 after a user-gesture click (bare `.play()` is blocked by autoplay policy, not
  codecs). The original "no codecs" reading does not reproduce; this is NOT a current
  ghosthands advantage. The native-app gap (Task 9) is the only durable structural miss.

## The core finding — the honesty models differ fundamentally

- **ghosthands = honesty ENFORCED by the tool.** Every verb self-classifies
  VERIFIED / DISPATCHED / REFUSED; fill/type read back; click admits "dispatched, unverified"
  when it can't prove. The tool refuses to lie.
- **agent-browser = honesty AVAILABLE, not default.** Every action prints `✓ Done` with no
  read-back. The truth is obtainable (snapshot shows `checked=true`, `get value` reads back),
  but the *agent* must verify — the tool won't assert it.
- **A real false positive was caught:** `fill input[name=delivery] 18:30` printed `✓ Done`
  while the value stayed **empty** (a custom time widget ignored the fill). ghosthands' built-in
  read-back would have reported DISPATCHED-or-REFUSED there; on agent-browser it was only caught
  by manually running `get value` afterward. This is exactly the refuse-or-verify contract that
  is ghosthands' differentiator.

## Where each wins

| Dimension | ghosthands | agent-browser |
|---|---|---|
| Pure web read / click / fill | ✅ | ✅ |
| Native macOS app (TextEdit, …) | ✅ (AX, whole Mac) | ❌ out of scope (browser/Electron only) |
| YouTube / DRM video playback | ✅ (drives real Brave) | ✅ (re-test 0.27.0 — plays; the original "no codecs" finding is stale) |
| Honesty | **enforced** (verify-or-refuse) | available (agent must verify; `✓ Done` ≠ verified) |
| Per-call speed | <0.11s typical | ~0.16–0.21s typical (both fast) |
| Multi-element extract | trivial (`web eval`) | clunky (container text / grep the snapshot) |
| Control-state visibility | read-back per verb | **visible in snapshot** (`checked=`, `[selected]`) |
| Element addressing | name + frame + CSS selector | clean `snapshot -i` **@refs** |

## Mineable ideas from agent-browser (potential backlog, not yet filed)

- **Stable `@ref` element handles** from a snapshot (agent-browser's `snapshot -i`) — a clean
  way to address an element across calls without re-resolving by name.
- **Surface control STATE in `snapshot`/`find`** (e.g. `checked=`, `[selected]`, expanded) so a
  toggle's state is visible without a separate read — complements ticket #6.
- A **"get all matching"** convenience (ghosthands already covers this via `web eval` / `extract`).

agent-browser's own rough edges (for the record): `fill` never verifies (silent false success on
the time widget), `focus ≠ click` for native web widgets, single-element reads only, daemon
serialization blocked a command 16–18s behind a stray background wait, and `wait --load
networkidle` burns its full timeout on never-idle pages.

## Verdict

Both tools are fast and have a clean read surface. The decisive differences are **structural**
(ghosthands drives the whole Mac + real Brave; agent-browser is browser-only with bundled
Chromium) and **philosophical** (ghosthands *enforces* honesty per verb; agent-browser makes it
*available* but prints `✓ Done` regardless — a silent failure looks identical to a success). The
head-to-head false positive is the clearest evidence for the verify-or-refuse contract.
