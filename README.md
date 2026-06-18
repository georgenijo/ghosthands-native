<div align="center">

# 👻 GhostHands

### Invisible, honest hands for the whole Mac.

**It drives any macOS app — no cursor move, no focus steal — and it never lies about whether it worked.**
Every action comes back **`verified`**, **`dispatched-unverified`**, or **`refused`**. Never a fake `success: true`.

`v0.8.0-m4` · **657 hermetic tests, 0 failures** · CLI · `--json` · **31-tool MCP server** · built on [AXorcist](https://github.com/steipete/AXorcist) (MIT), zero other deps

</div>

---

## Why it's different

Most automation tools click and print `✓ Done`. They can't tell a real success from a silent no-op — so they guess, and sometimes they're wrong. GhostHands is built on one rule:

> **Prove the effect, or admit you couldn't. Never fake it.**

```
verified              → it OBSERVED the effect (value read back, page URL changed, menu appeared). Trust it.
dispatched-unverified → it acted, but couldn't prove the result. Honest. NOT a success claim.
refused               → it won't guess (ambiguous target, occluded element, no permission). Clean no-op, nonzero exit.
```

Real output, verbatim:

```console
$ ghosthands web click "a" "Brave Browser" --cdp
clicked "a" in Brave Browser — verified: navigated "https://example.com/" → "https://www.iana.org/help/example-domains"

$ ghosthands web fill "#searchInput" "Barack Obama" "Brave Browser" --cdp
filled "#searchInput" in Brave Browser — verified: field value reads back "Barack Obama"

$ ghosthands click "Delete" Mail
click failed: "Delete" is ambiguous — 3 controls match — use a more specific name   # exit 1, nothing pressed
```

It's also **invisible by default**: it acts through the Accessibility tree (and CDP for the web), so the cursor never moves and the foreground app never changes. The one labelled exception is `--visible`, for surfaces with no accessibility at all.

---

## Quickstart

```sh
git clone https://github.com/georgenijo/ghosthands-native && cd ghosthands-native
swift build                 # only dep is AXorcist
swift test                  # 657 hermetic tests (no live app driven)

GH=.build/debug/ghosthands
$GH version                 # 0.8.0-m4
$GH snapshot Calculator     # read the AX tree
$GH click "7" Calculator    # press a control by name — honest verdict
```

`<app>` resolves by name / bundle id / pid. `<name>` matches a control's title / label / value / identifier / description — it presses only **actionable, enabled** controls, **refuses on ambiguity**, and reports `verified` only when it can observe the effect.

Needs **Accessibility** permission (and **Screen Recording** for `shot`). Local-only — no cloud, no telemetry.

---

## What it can do

**🔎 See** &nbsp;`snapshot` · `find` · `shot` · `extract` (tables/lists → rows) · `windows`

**🖱️ Act** &nbsp;`click` · `type` · `set-value` · `doubleclick` · `right-click` · `act` (open/confirm/pick/…) · `focus` · `scroll` · `drag` · `key` · `window move/resize/raise`

**🌐 Web (AX + Chrome DevTools Protocol)** &nbsp;`web read` · `web tabs` (incl. background tabs) · `web click <css>` · `web fill <css>` · `web html` · `web eval` · `navigate`

**✅ Test** &nbsp;`assert exists|absent|value|count` (exit 0 pass / 1 fail / 2 can't-check) · `wait` (deterministic poll, hard deadline) · locator flags `--nth`/`--role`/`--text`

**⚙️ System** &nbsp;`clipboard read/write` · `install <dmg>` · `record` / `replay`

Every verb honors the same honesty contract, and **every verb speaks `--json`**:

```console
$ ghosthands clipboard write "ship it" --json
{"verb":"clipboard","status":"verified","target":"write","evidence":"read-back matches (7 chars)","fields":{"intendedChars":7,"readbackChars":7}}
```

---

## Drive the web (real DOM, real proof)

```sh
# 1. spin up an isolated, throwaway debug browser (never your real profile)
open -na "Brave Browser" --args --remote-debugging-port=9222 --user-data-dir=/tmp/gh https://en.wikipedia.org

# 2. read it, fill it, click it — each step verified
$GH web read  --cdp --debug-port 9222 "Brave Browser"
$GH web fill  "#searchInput" "Octopus" "Brave Browser" --cdp --debug-port 9222   # verified by read-back
$GH web html  "#searchInput" "Brave Browser" --cdp --debug-port 9222            # outerHTML + attrs + computed
$GH web eval  "document.title" "Brave Browser" --cdp --debug-port 9222
```

CDP is **additive beside AX**, **loopback-only**, and **connect-to-an-already-open-port by default** — a closed port refuses unless you opt in with `--relaunch` (which spins an isolated, ephemeral-port, throwaway-profile instance and reads the real port from the `DevToolsActivePort` sidecar). It never silently enables a debug surface and never touches your real browser profile.

---

## Plug in any agent (MCP)

```sh
.build/debug/ghosthands-mcp     # stdio JSON-RPC: initialize / tools/list / tools/call
```

The full verb surface is exposed as **31 MCP tools**. Results reuse the same JSON envelope as the CLI; a refuse maps to `isError`, a `dispatched` never reads as `verified`. Any agent — Claude, a local model, your own — plugs in and drives the whole Mac, honestly.

---

## Proven under live load

A **fresh, zero-context agent** was handed only the manual and turned loose on 11 real tasks across live websites and a real Mac (Hacker News, Wikipedia, DuckDuckGo, BBC, httpbin forms, YouTube, Google Maps, cross-app into TextEdit):

> **11 / 11 complete · honest throughout · no crashes · no fake successes.**
> Everything it marked `dispatched` was independently confirmed to have actually happened. **~16 s of tool time out of 439 s total** — the rest was page/network, not the tool. Every resolve stayed under a second.

Run head-to-head against a leading web-only automator on the same 11 tasks, the other tool printed `✓ Done` on a form fill that **silently did nothing** — a false positive GhostHands' read-back makes impossible. Full write-up: [`docs/STRESS-TEST-0.8.0.md`](./docs/STRESS-TEST-0.8.0.md).

---

## Honest about scope

GhostHands is the **hands + eyes**. The **brain is yours** — it plugs in whatever agent you want. Out of scope on purpose: the goal-planner, the phone bridge, "text-it-a-task."

Deferred (tracked as issues): **menu bar / Control Center** (hard — SwiftUI `MenuBarExtra` `AXPress` is a no-op), **always-on daemon + push-events**, **vision/OCR** for canvas-only surfaces, **packaging/notarization**. Where it can't see (a bare `<canvas>`, a DRM video control), it **says so** — it doesn't pretend.

---

**State & full plan:** [ROADMAP.md](./ROADMAP.md) (the capability matrix — every row ✅ except the two deferred) · **Changelog:** [CHANGELOG.md](./CHANGELOG.md) · **License:** [MIT](./LICENSE) · [ATTRIBUTION.md](./ATTRIBUTION.md)
