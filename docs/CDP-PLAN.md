# CDP / DOM Web Path — Design Plan

Status: **planned** (build after the navigate / key / web-frames verbs land).
Source: design scout pass, 2026-06-18. Reference blueprint = the old Python build.

## Summary

Add a **deeper, additive CDP lens** that drives a Chromium browser (Brave/Chrome)
over its real DOM — query by CSS selector, get the exact element + its box, click
it dead-on, read outerHTML, list every tab without fronting one. CDP **never
replaces AX**: AX stays the universal layer (only eyes for native apps, and the
fallback when the debug port is off). The two form a fallback chain — **CDP when a
debug port is reachable + the selector resolves; AX otherwise** — and every CDP
action runs the SAME honesty contract: `verified` only on an observed world-change
(a DOM/URL/attribute read back after the act), `dispatched-unverified` when the DOM
accepted the action but nothing observable changed, `refuse` on no-port / no-element
/ ambiguous. **Hand-roll the CDP client over `URLSessionWebSocketTask` (no new
dependency)** — keep the dep surface at AXorcist only.

## Prior art (reuse as concepts, not code)

The old Python repo `/Users/george-mac-mini/Documents/code/ghosthands` has a
complete, stdlib-only CDP tier — a near-perfect blueprint:
- `src/ghosthands/webtier.py`:
  - Target discovery over HTTP: `GET 127.0.0.1:<port>/json/list`, filter `type=="page"`,
    each entry has `id`/`url`/`title`/`webSocketDebuggerUrl`. `target_for_url` binds a
    **background** tab by URL substring (the gap AX can't do — AX only sees the front tab).
  - A hand-rolled RFC 6455 websocket — **replaced in Swift by `URLSessionWebSocketTask`**
    (that ~170-line layer disappears).
  - A JSON-RPC session: send `{id, method, params}`, **match reply by `id` while skipping
    Chromium's interleaved event frames**, with a **wall-clock deadline so a missing reply
    raises instead of hanging** — the single most important behavior to port.
  - Actuation + honesty: act, then **re-evaluate a JS predicate AFTER** — `.click()` fired
    is upgraded to verified only when the post-act read confirms a change; a no-op click is
    reported false, never faked. (= our `verified` vs `dispatched-unverified`.)
  - `Page.navigate` returns on **commit, not load** — report honestly, don't claim "loaded".
  - Launch with `--remote-debugging-port` + an **isolated `--user-data-dir`** so automation
    never touches the user's working browser.
- `tests/test_webtier.py` — hermetic blueprint: an in-memory `_FakeSocket` replays crafted
  frames; asserts id-match skips events, answers pings, raises on close/timeout/deadline,
  filters `/json/list` to pages, raises on malformed JSON. No browser, no network.

## Architecture — new `GhostHandsKit/CDP/` group

| File | Role | Pure? |
|---|---|---|
| `CDP/CDPTarget.swift` | decode + page-filter a `/json/list` entry from raw `Data` (mirrors `Install.mountPoint(fromAttachPlist:)`) | PURE |
| `CDP/CDPMessage.swift` | encode `{id,method,params}`; decode reply; classify frame as our-reply / foreign-event / error (id-match + event-skip) | PURE |
| `CDP/CDPSession.swift` | owns a `URLSessionWebSocketTask`; `call(method:params:deadline:)` sends, loops `receive()` skipping foreign ids until match or deadline | impure (thin) |
| `CDP/CDPDiscovery.swift` | `GET /json/list` + `/json/version` via `URLSession`; `isPortOpen(port:)` for the fallback decision | impure (thin) |
| `CDP/CDPLaunch.swift` | (late) the `Install.swift` `Foundation.Process` idiom to relaunch with `--remote-debugging-port` + isolated `--user-data-dir`, gated by consent | impure |
| `CDP/CDPVerdict.swift` | pure web verdict: before/after DOM facts → verified / dispatched (sibling to `ValueVerdict`) | PURE |
| `CDP/WebCDP.swift` | orchestration: `webReadCDP`/`webTabsCDP`/`webClickSelector`/`webNavigate`/`webOuterHTML`, returns existing `…Result`/`…Outcome` types | impure (thin) |

`Web.swift` (AX path) is untouched and authoritative for AX; `WebCDP.swift` is a
parallel path. Hand-rolled JSON-RPC precedent already in the repo:
`Sources/GhostHandsKit/MCP/JSONRPC.swift`. `URLSessionWebSocketTask` owns RFC 6455
(handshake/masking/framing/ping-pong) — less hand-rolled than the Python build.
CDP verbs slot in as `async throws` (the kit already has async verbs).

## Security — debug port

`--remote-debugging-port` is a real control surface (any local process on
`127.0.0.1:<port>` can read every tab + cookies + navigate). Treat as a privilege,
never silent.

1. **Default: connect to an ALREADY-open port only.** Probe `/json/version`. Reachable →
   CDP. Not reachable → for read/tabs **fall back to AX**; for CDP-only verbs **REFUSE**
   with a remedy message (`cdpPortClosed(app:port:)`: "no DevTools port on 127.0.0.1:9222 —
   relaunch with `--remote-debugging-port=9222`, or use `web read` (AX); refusing to enable
   a debug surface silently").
2. **Opt-in relaunch** behind an explicit flag + loud stated-cost warning (loses session;
   port is a control surface). **Recommend `--isolated` (dedicated `--user-data-dir`)** so the
   user's real profile/cookies/session are untouched. Never relaunch the primary profile by default.
3. **Loopback only, always.** Only talk to `127.0.0.1`; refuse any `webSocketDebuggerUrl`
   whose host isn't loopback.
4. Default discovery port `9222` (Chromium default), overridable `--debug-port`.

REFUSE (never silently succeed): port closed for a CDP-only verb; non-loopback URL;
malformed `/json/list`; selector matches nothing; vanished target id.

## AX ↔ CDP fallback rule

Auto-detect, CDP-preferred-when-reachable, AX-always-working:
```
target is a browser AND a debug port is reachable?
  yes → CDP (precise DOM: selectors, exact box, real .click(), every tab incl. background)
  no  → AX  (universal: existing Web.swift AXManualAccessibility path)
```
- `web read` / `web tabs`: auto. CDP closes the `tabsNotExposed` gap (all tabs incl.
  background, with URLs). Port closed → fall through to AX unchanged (no regression).
- `--cdp` / `--ax` override flags (force a lens). Default = auto.
- CDP-only verbs (`web click <selector>`, `web navigate`, `web html`) require a port → refuse otherwise.
- Routing signal (port `route_surface`): browser only if bundle-id hints browser OR AX snapshot has an `AXWebArea`. Native apps never attempt CDP.

## Verb surface + honest verdicts

| Verb | New? | CDP | AX fallback | Verdict |
|---|---|---|---|---|
| `web read <browser> [--cdp\|--ax] [--debug-port N]` | extend | DOM digest (roles/names/values/boxes) | existing `webRead` | pure read, honest empty; reports which lens |
| `web tabs <browser> [--cdp\|--ax]` | extend | `/json/list` (all tabs + URLs) | existing `webTabs` | pure read; CDP closes `tabsNotExposed` |
| `web navigate <url> <browser>` | NEW | `Page.navigate` | refuse if port closed | **dispatched-unverified** (commit≠load); verified only if post-settle `location.href` matches |
| `web click <selector> <browser>` | NEW | `deepQuery`→`el.click()` (+ optional `Input.dispatchMouseEvent` at box) | refuse if port closed / not-found / ambiguous | **verified** only on post-act read-back change; **dispatched-unverified** on DOM-accepted no-op |
| `web html <selector> <browser> [--outer\|--computed]` | NEW | `DOM.getOuterHTML` / `getComputedStyle` | refuse if port closed | pure read, honest not-found |

New `GhostHandsError`: `cdpPortClosed(app:port:)`, `cdpTargetVanished(id:)`,
`selectorNotFound(selector:app:)`, `selectorAmbiguous(selector:count:)`, `cdpTransport(reason:)`.

## Hermetic tests (no live browser — the rail)

- `CDPTarget` decode/filter on a fabricated `/json/list` `Data` (filter to pages; raise on malformed).
- `CDPMessage` encode + id-match classifier (return our reply, skip foreign event, surface error reply).
- `CDPVerdict.decide(...)` — fabricated before/after → verified only on real change (the honesty test).
- `CDPSession` over a **fake transport protocol** (one real `URLSessionWebSocketTask` impl + one fake
  replaying crafted frames) → test the **deadline-stops-the-loop** behavior with no socket.

Impure files (`CDPDiscovery`, the real socket, `CDPLaunch`) exercised only in manual live-verify.

## Build slices (after navigate / key / web-frames land)

1. **Session + discovery + read (the spine).** `CDPTarget` + `CDPDiscovery` + `CDPMessage` +
   `CDPSession` (id-match + deadline). Wire `web read --cdp` / `web tabs --cdp`; fall back to AX
   when port closed. New error `cdpPortClosed`. Live-verify: isolated Brave on 9222, read a
   **background** tab's DOM AX can't see. Ships the deepest immediate win (background-tab + full-tab-list).
2. **navigate + click-by-selector + the honest verdict.** `CDPVerdict` + `web navigate` (commit caveat)
   + `web click <selector>` with the **post-act read-back verdict** (DOM-accepted no-op = dispatched).
   The honesty centerpiece.
3. **outerHTML / computed read.** `web html <selector> [--outer|--computed]`. Pure read, honest not-found.
4. **Consent launch + fallback polish + docs.** `CDPLaunch` behind `web launch --debug-port [--isolated]`
   with the loud warning; `--cdp`/`--ax` flags everywhere; routing signal; MCP tool entries; flip the
   ROADMAP/CHANGELOG "CDP = future" markers.

## Slots into (current repo)

`Web.swift` (AX path + `GhostHands.webRead/webTabs` extension ~343-426 where fallback wiring lives);
`Errors.swift` (new cases + descriptions); `CLI.swift` (`runWeb` dispatch + new sub-verbs + usage block);
`MCP/MCPTools.swift` (advertise new verbs); `Install.swift` (Process idiom for `CDPLaunch`);
`ValueVerdict.swift` + `Witness.swift` (verdict pattern `CDPVerdict` mirrors);
`MCP/JSONRPC.swift` (hand-rolled JSON-RPC precedent, no dep).
Reference blueprint: `/Users/george-mac-mini/Documents/code/ghosthands/src/ghosthands/webtier.py` + `tests/test_webtier.py`.
