import Foundation

/// The PURE decider for the `assert`/`expect` verbs — the machine-checkable
/// assertion core, kept AX-free so it is hermetically testable over FABRICATED
/// observations (no live app driven).
///
/// HONESTY contract (the whole point of this tier):
/// - A verdict is PASS *only* on the OBSERVED condition. There is no "default
///   green": every PASS is computed from a real observation, and every FAIL
///   renders the ACTUAL vs the EXPECTED so a test harness (and a human) sees
///   exactly what was wrong — never a bare "failed".
/// - An app/element that could not be READ AT ALL is NOT a FAIL: it is a REFUSE,
///   raised as a `GhostHandsError` by the live layer and surfaced as a distinct
///   exit code. This decider only ever sees a genuine observation, so it only
///   ever emits PASS or FAIL — never a refuse. The split (FAIL = the assertion
///   was checked and did not hold; REFUSE = the assertion could not be checked)
///   is the honesty boundary, mirrored from the act tier's
///   verified / dispatched / refuse split.
///
/// The observation is supplied by the caller (the live `Assert.swift` builds it
/// from the bounded `Finder`; the tests fabricate it), so this file touches no
/// accessibility API and can be reasoned about in isolation.
public enum AssertVerdict {
    /// What is being asserted. Each case carries the EXPECTED side of the
    /// comparison; the OBSERVED side arrives in `Observation`.
    public enum Kind: Sendable, Equatable {
        /// PASS iff the named control resolves (is present).
        case exists
        /// PASS iff NO control of that name resolves (is absent).
        case absent
        /// PASS iff the control's read-back value EQUALS `expected`.
        case valueEquals(String)
        /// PASS iff EXACTLY `expected` controls match the name.
        case countEquals(Int)
    }

    /// The OBSERVED facts gathered for the named control — the only input that
    /// can move the verdict. Fabricated in tests, read off the bounded Finder
    /// live. `count` is the number of DISTINCT controls that matched the name;
    /// `present` is `count > 0` made explicit (so `exists`/`absent` need not
    /// re-derive it). `value` is the read-back value of the resolved control —
    /// it is `.some` only when EXACTLY ONE control resolved (a value assertion
    /// over an ambiguous name is a refuse, handled upstream, never silently
    /// compared against an arbitrary match).
    public struct Observation: Sendable, Equatable {
        public let count: Int
        public let value: String?

        public init(count: Int, value: String?) {
            self.count = count
            self.value = value
        }

        /// Convenience constructors so a test reads as the thing it fabricates.
        public static func present(count: Int = 1, value: String? = nil) -> Observation {
            Observation(count: count, value: value)
        }
        public static let missing = Observation(count: 0, value: nil)

        public var present: Bool { count > 0 }
    }

    /// PASS or FAIL — and ONLY those two. A refuse never reaches here (it is a
    /// thrown error in the live layer). Each carries the rendered, human-and-
    /// harness-readable one-liner; FAIL always states the ACTUAL alongside the
    /// EXPECTED.
    public enum Verdict: Sendable, Equatable {
        case pass(String)
        case fail(String)

        public var passed: Bool {
            if case .pass = self { return true }
            return false
        }
        /// The rendered message either way.
        public var message: String {
            switch self {
            case let .pass(m), let .fail(m): return m
            }
        }
    }

    /// Decide the verdict from the assertion KIND and the OBSERVATION alone.
    ///
    /// - `name` is echoed into the message so the report names the subject.
    ///
    /// The comparisons are deliberately literal: `valueEquals` is an EXACT
    /// string equality (an empty read-back is normalised to "" so a blank field
    /// and a never-set field compare the same), `countEquals` is exact arity.
    /// Nothing here "moves toward" or fuzzily matches — an assertion is a hard
    /// equality, and a near-miss is a FAIL with the actual quoted, never a soft
    /// pass.
    public static func decide(_ kind: Kind, name: String,
                              observed: Observation) -> Verdict {
        switch kind {
        case .exists:
            if observed.present {
                return .pass("PASS: \(q(name)) exists (\(observed.count) match"
                    + "\(observed.count == 1 ? "" : "es"))")
            }
            return .fail("FAIL: \(q(name)) does not exist (expected present, "
                + "found 0 matches)")

        case .absent:
            if !observed.present {
                return .pass("PASS: \(q(name)) is absent (0 matches)")
            }
            return .fail("FAIL: \(q(name)) is present (expected absent, found "
                + "\(observed.count) match\(observed.count == 1 ? "" : "es"))")

        case let .valueEquals(expected):
            let actual = normalize(observed.value)
            let want = normalize(expected)
            if actual == want {
                return .pass("PASS: \(q(name)) value == \(quote(observed.value)) "
                    + "(expected \(quote(expected)))")
            }
            return .fail("FAIL: \(q(name)) value is \(quote(observed.value)), "
                + "expected \(quote(expected))")

        case let .countEquals(expected):
            if observed.count == expected {
                return .pass("PASS: \(q(name)) count == \(observed.count) "
                    + "(expected \(expected))")
            }
            return .fail("FAIL: \(q(name)) count is \(observed.count), "
                + "expected \(expected)")
        }
    }

    /// Treat "" the same as nil for value equality — an empty AXValue and an
    /// absent one are the same observable (a blank control). Mirrors
    /// `ValueVerdict.normalize` so the two value paths agree on what "empty"
    /// means.
    static func normalize(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Quote a value for the message; a nil/empty read-back is the honest word
    /// "empty" (never a fabricated string, never the literal "nil").
    static func quote(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "empty" }
        return s.debugDescription
    }

    /// Quote a NAME for the message — always shown so the subject is explicit.
    static func q(_ s: String) -> String { s.debugDescription }
}
