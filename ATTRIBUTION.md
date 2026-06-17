# Attribution

GhostHands (native) is built on, and ports techniques from, the following
MIT-licensed projects by Peter Steinberger (@steipete):

- **AXorcist** — https://github.com/steipete/AXorcist (MIT) — the Accessibility
  library this package depends on (the `Element` wrapper, window resolution,
  permission helpers).
- **Peekaboo** — https://github.com/steipete/peekaboo (MIT) — reference for
  target resolution (process name / bundle id → app + window) and scored
  name-based element resolution.

What GhostHands deliberately does **not** port from Peekaboo: its
unconditional `success: true` reporting (e.g. `ClickCommand.swift`,
`SetValueCommand.swift`). GhostHands replaces that with mandatory
read-the-world-back verification after every action — an action that cannot be
confirmed is reported as a failure, never papered over.

Both upstream projects are MIT-licensed; their copyright notices are retained
here in accordance with that license.
