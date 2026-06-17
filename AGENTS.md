# AGENTS.md — operating contract for GhostHands-native

Read this first, then [ROADMAP.md](./ROADMAP.md) (state + plan) and
[DESIGN.md](./DESIGN.md) (spec). Decisions: [docs/decisions/DECISIONS.md](./docs/decisions/DECISIONS.md).

## What this is

Invisible, honest hands for macOS. `ghosthands click "<name>" <app>` presses a
named control through the Accessibility tree — **no cursor move, no focus
steal** — and reports the **honest** result. The whole product thesis is
honesty + invisibility; everything else is a feature on top.

**This is a TOOL, not an agent.** It is the hands + eyes that ANY agent plugs
into — via an MCP server / CLI / Swift library — to drive the whole Mac. The
brain, the phone, "text-it-a-task", remote auth → **out of scope**; George owns
those and brings his own agent. Your job: make this tool able to do *anything on
screen*, invisibly and honestly, for whatever brain is driving.

## Prime directive — honesty

**Never report success you cannot prove.** Every action resolves to one of:
- **verified** — an observed world-change (value flip, or the target no longer
  matching after the action),
- **dispatched (unverified)** — AX accepted the action but no observable proof
  exists from the element alone (say so plainly; do NOT imply success),
- **refuse** — not found / ambiguous / rejected → clean one-line stderr, exit ≠ 0.

There is no fourth option. No hardcoded `success: true`. This is the line that
separates us from Peekaboo (which fakes success).

## Hard rules

1. **AX only.** Act via `AXUIElementPerformAction` / AX attributes. No synthetic
   pixel clicks, no `cliclick`, no `CGEventPost` at another app, no
   `open -a`/`activate`. Never foreground the user's app, never move the cursor.
2. **Verify by the world, never by memory of acting.** Re-read on a *fresh*
   snapshot; pin the read-back to the same control by identity.
3. **Refuse on ambiguity.** >1 distinct control (or >1 partial app match) → stop,
   don't guess. Only actionable + enabled controls are candidates.
4. **Tests are hermetic.** Unit tests use fabricated facts — **never drive a live
   app in a test** (George's rule). Live apps are for the live-verify step only.
5. **Don't damage real apps.** When live-verifying against the user's running
   apps, never press destructive controls (e.g. OrbStack Stop/Trash/Play).
6. **No AI/Claude/Anthropic attribution** in commits, PRs, branches, or issues.
   No `Co-Authored-By` lines.

## Per-milestone workflow (how to churn the ROADMAP)

Work milestones **in order** (M2 → M3 → …). For each:

1. Build the verb(s) — reuse the M1 shape (`Target` resolve → `Finder` find →
   act → read-back → honest verdict). Keep pure logic separate from AX so it's
   unit-testable.
2. `swift build` green (fix loop).
3. `swift test` green — **hermetic**, add tests for the new pure logic.
4. **Live-verify**, world-checked: launch a target app in the *background* via
   the cua-driver MCP (`launch_app`), drive it with `ghosthands`, confirm via cua
   (`get_window_state`, `get_cursor_position`, `list_apps`) that it worked, the
   cursor didn't move, and the app stayed `active:false`.
5. **Adversarial honesty review** — spawn a reviewer agent: can it report success
   without proof? wrong-target? Fix what's real before moving on.
6. Commit → push → tick the ROADMAP checkbox.

## Build / test / run

```sh
swift build                                    # Swift 6.3.2 / Xcode 26.5; uses only AXorcist
swift test                                     # hermetic
.build/debug/ghosthands click "<name>" <app>   # e.g. click "7" Calculator
```

## Gotchas (will bite)

- AXorcist getters (`role()/title()/value()/children()/searchElements`) are
  `@MainActor`; the CLI entry is `@MainActor`.
- `Element.supportedActions()` can return **nil for a genuinely pressable
  button** → gate candidates on the **control-role allowlist** (`Finder.controlRoles`),
  not on AXPress support.
- `press()/pick()/showMenu()` return `Bool` (false = AX rejected). App element =
  `Element(AXUIElementCreateApplication(pid))`. Name→app via `NSWorkspace`.
- Apps can render **two AXWindow subtrees** → collapse by identity.
- AX needs **Accessibility** permission only (no Screen Recording). The launching
  terminal already holds the grant on the dev machine.
- AXorcist source to read its real API: `.build/checkouts/AXorcist/Sources/AXorcist/`.

## Full autonomy — churn, don't ask

Work all milestones (M2 → M5) start to finish **without stopping to ask**. Make
every technical call yourself — design, dependencies, code-signing, the MCP
shape, all of it. Use the computer freely to build and verify (launch/drive
apps, install/remove *test* apps to exercise drag-and-drop, etc.). Decide → do →
verify → move on. The only limits are the rails below — quality guarantees, not
questions:
- honesty + invisibility (the product),
- hermetic tests,
- don't destroy George's real data/work/files (drive apps freely; just don't
  trash his actual stuff),
- no AI/Claude/Anthropic attribution in git artifacts.

Everything else: just work. Don't stop until the ROADMAP is all ✅.

## Resume (next session)

Run this as a `/loop` prompt — it is both the mission and the loop body:

> GOAL: make GhostHands-native a COMPLETE, honest, invisible macOS computer-use
> tool that ANY agent can plug into (MCP / CLI / library) and drive the whole
> Mac — every ROADMAP capability-matrix row ✅. The brain + phone are out of
> scope (George's). Read AGENTS.md + ROADMAP.md + DESIGN.md, then **churn all
> milestones M2 → M5 in order, fully autonomously — never stop to ask.** Per
> milestone: build → `swift build` green → `swift test` green (**hermetic —
> never drive a live app in tests**) → **live-verify** world-checked against a
> real *background* app (launch via cua; confirm no focus steal, no cursor move)
> → spawn an **adversarial honesty review** → commit → push → tick the checkbox.
> Make every call yourself; use the computer freely to build/test. Only rails:
> honesty + invisibility, hermetic tests, don't trash my real data, no AI
> attribution in git. **Start: M2** — read verbs (snapshot/find/shot) + the
> effect-witness so a digit press verifies "0→789" instead of "unverified". Don't
> stop until the ROADMAP is all ✅.
