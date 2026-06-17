# GhostHands-native

Invisible, honest hands for macOS. Clicks/controls any app through the
Accessibility tree — **no cursor move, no focus steal** — and tells you the
truth about whether it worked: **verified**, **pressed-but-unproven**, or
**refused**. Never fakes success.

Built on [AXorcist](https://github.com/steipete/AXorcist) (MIT). This is the
native Swift rewrite of GhostHands and the foundation for a phone-controlled,
whole-Mac agent. **See [ROADMAP.md](./ROADMAP.md) for state + the plan.**

## Quickstart

```sh
swift build
swift test                                    # 16 hermetic tests
.build/debug/ghosthands click "<name>" <app>  # e.g. click "7" Calculator
```

`<app>` resolves by name / bundle id / pid. `<name>` matches a control's
title / label / value / identifier / description. It only presses actionable,
enabled controls, refuses on ambiguity, and reports a verified effect only when
it can observe one.

## Status

**M1 shipped:** one verb (`click`), honesty model, live-verified against a
backgrounded Calculator. Read-the-screen, type, dialogs, menu bar, drag-drop,
multi-monitor, the brain, and the phone bridge are the roadmap — see ROADMAP.md.

Licensing/attribution: [LICENSE](./LICENSE) (MIT), [ATTRIBUTION.md](./ATTRIBUTION.md).
