# Decisions Log — GhostHands-native

Architectural/scope decisions, newest first. (Mirrors the canonical cross-repo
log at `ghosthands/docs/decisions/DECISIONS.md` in the Python repo; this copy
keeps the native repo self-contained.)

---

## 2026-06-17: M1 — honesty-first AX click core (Swift, on AXorcist)

**Decision:** Bootstrap as a fresh Swift package depending on **AXorcist (MIT)** —
NOT a fork of the whole Peekaboo app (a fresh package dodges Peekaboo's Xcode-27
app-target wall; Swift 6.3.2 builds it). M1 = one verb, `ghosthands click
"<name>" <app>`, cursor-less and background-safe via AX, no model. Honesty baked
in: report a **verified** effect only on an observed world-change (value flip, or
the target no longer matching after the press), else say "AXPress accepted;
effect unverified" — never a hardcoded `success: true`. Candidates are
actionable+enabled controls only; ambiguity refuses rather than pressing an
arbitrary control.

**Rationale:** Proves the hands-core choice by building on it. An adversarial
review caught the one real honesty hole — `press()==true` is *dispatch*, not
*effect* — and the fix (verified-vs-dispatched wording, identity-pinned
read-back, ambiguity refusal, actionable-only candidates) is the discipline that
differentiates this from Peekaboo. Live-verified against a backgrounded
Calculator: never foregrounded, cursor never moved, world-checked via an
independent cua snapshot ("Clear" → 759→0 verified; digit "9" → honest
"unverified" though the display did change; unknown → refuse). 16 hermetic tests.

**Status:** active

**References:** commits `2f1b5cd` (M1), `1cac117` (honesty fix); ATTRIBUTION.md;
ROADMAP.md (M2 = effect-witness + read verbs).

---

## 2026-06-17: Hands core = AXorcist (MIT), not cua-driver

**Decision:** The actuation core is **AXorcist (Swift, MIT)**, not cua-driver.
cua stays only as an optional cross-check, never the core.

**Rationale:** A scored read-only eval of both (8 dimensions) put AXorcist 34/40
vs cua 32/40, and the two decisive axes both favor AXorcist: **license** — cua
ships no LICENSE file (= all-rights-reserved) plus telemetry, so it cannot be
vendored/forked into a repo we own; AXorcist is MIT. **Hard surfaces** — AXorcist
ships menu-bar/dialog/window/multi-monitor support (the vision's hard 20%); cua
has none (drag only). Honesty was a wash (both lack element-level read-back and
need a verification layer added) — so it is not a reason to pick cua, and
AXorcist's open Swift makes the read-back clean to bake in.

**Status:** active

**References:** the M1 build (above) confirms AXorcist buildable on this machine;
supersedes any earlier cua-as-foundation lean.
