import Foundation

/// The PURE deciders for the `wait` verb — the unit-testable heart of a
/// deterministic condition wait (the testing backbone that replaces a magic
/// `sleep` with a real, observed condition).
///
/// `wait` polls `Finder.resolve` on a wall-clock DEADLINE loop; the live loop
/// (the impure half, in `Wait.swift`) is the ONLY part that touches AX. Every
/// decision it makes is delegated here so the honesty contract is hermetically
/// testable on fabricated observation sequences — never a live app:
/// - `decide(found:wantGone:)` turns ONE observation (does the element exist?)
///   into met / not-yet, honouring `--gone` (invert the sense),
/// - `evaluate(observations:deadline:)` replays a fabricated sequence of
///   (timestamp, found) samples against a deadline and reports the HONEST
///   outcome: met-at (the first sample whose condition held, with its elapsed)
///   or timed-out (the deadline passed and no sample ever met).
///
/// The cardinal sin this prevents: reporting "met" when the condition was NEVER
/// observed. A timeout is a REFUSE, never a fabricated success — so a sequence
/// that never satisfies `decide` MUST evaluate to `.timedOut`, no matter how
/// many polls it took.
public enum WaitVerdict {
    /// The verdict for ONE poll observation: is the waited-for condition met?
    public enum Poll: Sendable, Equatable {
        /// The observed presence matches what we are waiting for — STOP, success.
        case met
        /// Not yet — keep polling until the deadline.
        case notYet
    }

    /// Decide one poll from the OBSERVED presence and the wait sense.
    ///
    /// - `found`   : did this poll OBSERVE the named element on screen?
    /// - `wantGone`: are we waiting for the element to be ABSENT (`--gone`)?
    ///
    /// Without `--gone` we wait for existence: `found == true` → met.
    /// With `--gone` we wait for absence: `found == false` → met.
    /// It is the exact XOR — the only place the `--gone` sense is interpreted.
    public static func decide(found: Bool, wantGone: Bool) -> Poll {
        let conditionHeld = wantGone ? !found : found
        return conditionHeld ? .met : .notYet
    }

    /// One fabricated poll sample: when it was taken (seconds since the wait
    /// started) and what it OBSERVED. The pure-test surface — no AX, no clock.
    public struct Observation: Sendable, Equatable {
        /// Elapsed seconds since the wait began (monotonic, ≥ 0).
        public let elapsed: TimeInterval
        /// What this poll observed: was the element present?
        public let found: Bool
        public init(elapsed: TimeInterval, found: Bool) {
            self.elapsed = elapsed
            self.found = found
        }
    }

    /// The HONEST outcome of a whole wait, derived from a sequence of samples and
    /// a deadline — the deadline/elapsed bookkeeping the live loop reports.
    public enum Outcome: Sendable, Equatable {
        /// The condition was OBSERVED met. `elapsed` is the timestamp of the
        /// satisfying sample; `polls` is how many samples were taken up to and
        /// including it (1-based) — both quoted as evidence, never fabricated.
        case met(elapsed: TimeInterval, polls: Int)
        /// The deadline passed with the condition NEVER observed met — a REFUSE.
        /// `elapsed` is the last sample's timestamp (or 0 if none); `polls` is the
        /// total taken. The caller turns this into `.waitTimeout` (nonzero exit).
        case timedOut(elapsed: TimeInterval, polls: Int)
    }

    /// Replay a fabricated `observations` sequence against `deadline` seconds and
    /// decide met-at vs timed-out — the bookkeeping half, kept pure so the
    /// "never fake a met" guard is unit-testable on synthetic samples.
    ///
    /// Honesty rules, in order:
    /// 1. A sample is only ELIGIBLE to satisfy the wait if it was taken AT OR
    ///    BEFORE the deadline (`elapsed <= deadline`). A sample observed AFTER the
    ///    deadline is too late — the wall clock already expired — so it can never
    ///    flip a timeout into a (dishonest) success.
    /// 2. The FIRST eligible sample whose `decide(found:wantGone:)` is `.met`
    ///    wins → `.met(elapsed:, polls:)` with that sample's timestamp and its
    ///    1-based position.
    /// 3. If no eligible sample ever meets the condition → `.timedOut`, carrying
    ///    the last sample's elapsed (or 0 for an empty sequence) and the total
    ///    poll count. A timeout is a refuse, full stop — never a met.
    public static func evaluate(observations: [Observation], deadline: TimeInterval,
                                wantGone: Bool) -> Outcome {
        for (i, obs) in observations.enumerated() {
            // Rule 1: a post-deadline sample is too late to satisfy the wait.
            guard obs.elapsed <= deadline else { break }
            if decide(found: obs.found, wantGone: wantGone) == .met {
                return .met(elapsed: obs.elapsed, polls: i + 1)   // Rule 2
            }
        }
        // Rule 3: nothing met in time → timeout (refuse), honestly book-kept.
        let lastElapsed = observations.last?.elapsed ?? 0
        return .timedOut(elapsed: lastElapsed, polls: observations.count)
    }
}
