import AppKit
import ApplicationServices
import AXorcist
import Foundation

/// The `assert`/`expect` verbs — the UI-testing core. A machine-checkable
/// assertion for test harnesses: PASS (exit 0), FAIL (exit 1, the assertion was
/// CHECKED and did not hold — ACTUAL is reported), or REFUSE (exit 2, the
/// assertion could NOT be checked: app/permission failure).
///
/// HONESTY: an assertion is a hard equality computed from an OBSERVED condition
/// (`AssertVerdict` is the pure decider). The live layer here only GATHERS the
/// observation — using the bounded, cycle-safe `Finder` (NEVER a raw AXorcist
/// `searchElements`, which has no visited-set and HANGS/SIGSEGVs on a cyclic AX
/// tree). The distinction FAIL-vs-REFUSE is the honesty boundary: a real green
/// is only ever an observed pass, and an un-readable app is surfaced as a
/// distinct refuse, never a fake FAIL.
extension GhostHands {
    /// The result of running one assertion against the live tree.
    public struct AssertOutcome: Sendable, Equatable {
        public let app: String
        public let name: String
        public let verdict: AssertVerdict.Verdict
        /// The observation that drove the verdict — surfaced for auditability /
        /// a verbose harness, never re-derived from the message string.
        public let observed: AssertVerdict.Observation

        public var passed: Bool { verdict.passed }
        public var message: String { verdict.message }
    }

    /// Gather the PRESENCE observation for `name` under `root`: the count of
    /// DISTINCT controls matching the name (deduped via the same identity key
    /// `find` uses, so the duplicate-render quirk does not double-count), and —
    /// when EXACTLY ONE distinct control resolves — its read-back value.
    ///
    /// Uses the broad PRESENCE gate (like `find`): static labels and disabled
    /// controls count, because an assertion is about what is ON SCREEN, not only
    /// what is clickable. Bounded + cycle-safe: `presenceMatches` runs
    /// `searchElements(matching:options:)` with `maxDepth` set, and the dedupe is
    /// pure — no unbounded walk.
    @MainActor
    static func observe(name: String, under root: Element) -> AssertVerdict.Observation {
        // PRESENCE gate: the SHARED presence read `find` uses — name-matches
        // including static text AND disabled controls, NOT the actionable-only
        // click gate (which `candidateMatches`/`options()` would impose via
        // `enabledOnly`, silently dropping a visibly-disabled control). Dedupe
        // to distinct logical controls.
        let pairs = Finder.presenceMatches(named: name, under: root)

        let distinct = FindResult.dedup(pairs.map { $0.1 })
        let count = distinct.count

        // The read-back value is meaningful ONLY when exactly one distinct
        // control resolved. With several distinct matches, "the value" is
        // ambiguous — the value assertion refuses upstream rather than compare
        // against an arbitrary one, so we never need a value here.
        let value = (count == 1) ? distinct[0].value : nil
        return AssertVerdict.Observation(count: count, value: value)
    }

    /// Shared entry: resolve the app (REFUSE on app/permission failure — a
    /// distinct exit, never a FAIL), gather the observation off a settled tree,
    /// and decide. A cold first read can miss a just-rendered control, so when
    /// the first observation finds NOTHING and `settle > 0`, we re-read once off
    /// a fresh application element (the same one-retry pattern `find` uses) so a
    /// transient empty read is not mistaken for a genuine absence.
    @MainActor
    public static func assert(_ kind: AssertVerdict.Kind, name: String,
                              appSpec: String,
                              settle: TimeInterval = 0.4) throws -> AssertOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        var observed = observe(name: name, under: target.element)
        // One retry on an empty read — but ONLY when an empty read could be a
        // miss that changes the verdict. For `exists`/`value`/`count(n>0)` an
        // empty first read is worth a re-read; for `absent`/`count(0)` an empty
        // read is the EXPECTED state, so re-reading buys nothing (and a present
        // control is never the empty case anyway).
        if observed.count == 0, settle > 0, retryOnEmpty(kind) {
            Thread.sleep(forTimeInterval: settle)
            let fresh = Element(AXUIElementCreateApplication(target.pid))
            observed = observe(name: name, under: fresh)
        }

        // The VALUE assertion needs an UNAMBIGUOUS subject: comparing the value
        // of one of several same-named controls would be a coin-flip, the exact
        // wrong-target risk the click path refuses on. So a value assertion over
        // a name that resolves to >1 distinct control is a REFUSE (exit 2), not a
        // FAIL — the assertion could not be honestly checked.
        if case .valueEquals = kind, observed.count > 1 {
            throw GhostHandsError.ambiguousMatch(
                name: name, candidates: ambiguityLabels(name: name, under: target.element))
        }

        let verdict = AssertVerdict.decide(kind, name: name, observed: observed)
        return AssertOutcome(app: target.name, name: name, verdict: verdict, observed: observed)
    }

    /// Whether an empty first read warrants the single re-read. A read of zero
    /// only matters when the verdict would change if the control were actually
    /// there — i.e. when we are asserting PRESENCE (`exists`, `value`, or a
    /// positive `count`). Asserting ABSENCE / a zero count off an empty read is
    /// already the expected state.
    static func retryOnEmpty(_ kind: AssertVerdict.Kind) -> Bool {
        switch kind {
        case .exists, .valueEquals: return true
        case .absent: return false
        case let .countEquals(n): return n > 0
        }
    }

    /// Human labels of the distinct controls matching `name`, for an ambiguous
    /// value-assertion refuse. Reuses the dedupe + the `find` line renderer so
    /// the labels match what `find` would print.
    @MainActor
    static func ambiguityLabels(name: String, under root: Element) -> [String] {
        let pairs = Finder.presenceMatches(named: name, under: root)
        return FindResult.dedup(pairs.map { $0.1 }).map(FindResult.line)
    }
}
