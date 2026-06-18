import AppKit
import ApplicationServices
import AXorcist
import Foundation

/// The outcome of a `wait` — the condition was OBSERVED to hold within the
/// deadline. A timeout is NOT an outcome: it is a refuse (`.waitTimeout` thrown),
/// so by construction this struct only ever describes an honestly-met wait. It
/// carries the elapsed time and the poll count as auditable evidence, never a
/// bare "success:true".
public struct WaitOutcome: Sendable, Equatable {
    public let app: String
    public let name: String
    /// Were we waiting for the element to be GONE (`--gone`) or to EXIST?
    public let wantedGone: Bool
    /// Seconds elapsed (monotonic wall clock) when the condition was observed met.
    public let elapsed: TimeInterval
    /// How many polls were taken up to and including the satisfying one (1-based).
    public let polls: Int

    public init(app: String, name: String, wantedGone: Bool,
                elapsed: TimeInterval, polls: Int) {
        self.app = app
        self.name = name
        self.wantedGone = wantedGone
        self.elapsed = elapsed
        self.polls = polls
    }
}

extension GhostHands {
    /// `wait "<name>" <app> [--gone] [--timeout <s>] [--interval <ms>]` — the
    /// deterministic condition wait: poll `Finder.resolve` for the named element
    /// on a real wall-clock DEADLINE loop until the condition is OBSERVED met (or
    /// the deadline passes → REFUSE). The testing backbone — it replaces a magic
    /// `sleep` with a real, witnessed condition.
    ///
    /// Honesty contract (a timeout is a refuse, never a fake success):
    /// - throws `.accessibilityNotTrusted` if AX permission is missing,
    /// - WITHOUT `--gone`: returns as soon as the element EXISTS; if the deadline
    ///   passes still absent → throws `.waitTimeout`,
    /// - WITH `--gone`: returns as soon as the element is ABSENT; if still present
    ///   at the deadline → throws `.waitTimeout`,
    /// - reports elapsed seconds + poll count, derived ONLY from observed samples.
    ///
    /// The poll cadence is a bounded `interval` sleep BETWEEN checks (that is the
    /// poll rate, NOT a fixed guess at how long the work takes — the hard deadline
    /// is the real bound). Every existence check goes through `Finder.resolve`,
    /// which is DEPTH-BOUNDED (`Finder.maxSearchDepth`) — never an unbounded walk.
    ///
    /// Note: app resolution is INSIDE the loop. Waiting for an app's element to
    /// EXIST naturally includes waiting for the app itself to appear, so a
    /// not-yet-running app (and likewise an as-yet-unresolvable or ambiguous app
    /// spec) is just a `notYet` poll — the element cannot be uniquely observed, so
    /// the wait keeps polling and, if the deadline passes, REFUSES with
    /// `.waitTimeout`. It never throws an app-resolution error mid-wait.
    ///
    /// HEAVY-APP CAVEAT: one poll is a full bounded AX search, which on a large or
    /// cyclic tree can take SECONDS — longer than a short timeout. The deadline is
    /// enforced only AT POLL BOUNDARIES (an in-flight search can't be cancelled),
    /// so on such an app a timeout shorter than one poll's duration will refuse
    /// after the first overrunning poll even if the element is present. That is
    /// honest (we did not observe it in time), but it means `wait` is best used
    /// with a timeout comfortably larger than a single search on the target app.
    @MainActor
    public static func wait(name: String, appSpec: String, wantGone: Bool = false,
                            timeout: TimeInterval = 5, interval: TimeInterval = 0.15)
        throws -> WaitOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }

        // The hard wall-clock DEADLINE. Monotonic (Date()-based elapsed is fine
        // here; the deadline is relative to this captured start), so a system
        // clock change can't extend or collapse the wait.
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var polls = 0
        var resolvedAppName = appSpec

        while true {
            polls += 1
            // ONE observation: does the named element resolve right now? App
            // resolution is part of the observation — a not-yet-launched app
            // (or one with no matching control yet) is simply `found == false`.
            // NOTE: a single observation is a full DEPTH-BOUNDED AX search, which
            // on a large/cyclic tree can itself take many seconds (longer than a
            // short timeout). The deadline can only be enforced BETWEEN/AFTER an
            // atomic poll — never mid-walk — so the wall time may overshoot a
            // short timeout by up to one poll's duration (see the verb's docs).
            let found = observeFound(name: name, appSpec: appSpec,
                                     resolvedAppName: &resolvedAppName)
            let now = Date()
            let elapsed = now.timeIntervalSince(start)

            // THE DEADLINE FENCE (mirrors WaitVerdict.evaluate's Rule 1): a poll is
            // only ELIGIBLE to satisfy the wait if it COMPLETED at or before the
            // deadline. A poll that returned met but finished AFTER the deadline is
            // too late — the wall clock already expired — so it can NEVER flip a
            // timeout into a (dishonest) success. This is the live half of the same
            // fence the pure decider enforces on fabricated samples.
            let inTime = now <= deadline
            if inTime, WaitVerdict.decide(found: found, wantGone: wantGone) == .met {
                return WaitOutcome(app: resolvedAppName, name: name, wantedGone: wantGone,
                                   elapsed: elapsed, polls: polls)
            }

            // Past the deadline (this poll was the last in-budget chance, or it
            // already overran) → REFUSE. A met observed too late is NOT honoured
            // above, so reaching here with the deadline passed is a true timeout.
            if now >= deadline {
                throw GhostHandsError.waitTimeout(name: name, app: resolvedAppName,
                                                  wantedGone: wantGone, seconds: timeout)
            }

            // Otherwise sleep the bounded poll cadence and try again — but never
            // sleep PAST the deadline (clamp the final nap so we re-poll right at
            // the deadline rather than overrunning it by a whole interval).
            if interval > 0 {
                let remaining = deadline.timeIntervalSince(Date())
                if remaining <= 0 {
                    throw GhostHandsError.waitTimeout(name: name, app: resolvedAppName,
                                                      wantedGone: wantGone, seconds: timeout)
                }
                Thread.sleep(forTimeInterval: min(interval, remaining))
            }
        }
    }

    /// ONE existence observation for the poll loop — the impure, AX-touching half
    /// (deliberately NOT unit-tested; the decision logic it feeds IS). Resolves
    /// the app fresh each call (so a later-launching app is picked up) and runs
    /// the DEPTH-BOUNDED `Finder.resolve`. This NEVER throws — it only ever returns
    /// a Bool. EVERY app-resolution failure (not running yet, a transient AX read
    /// failure, or an AMBIGUOUS app spec) is swallowed by the `try?` below and
    /// reported as `found == false` — a `notYet` poll that keeps the wait polling,
    /// never an early abort (matching the verb-level doc: an unresolvable/ambiguous
    /// app spec is just `notYet`, and on the deadline it REFUSES with `.waitTimeout`).
    @MainActor
    private static func observeFound(name: String, appSpec: String,
                                     resolvedAppName: inout String) -> Bool {
        guard let target = try? Target.resolve(appSpec) else {
            return false   // app not running yet → keep waiting (existence wait)
        }
        resolvedAppName = target.name
        // The named element is "present" iff it RESOLVES to a unique pressable
        // control. Ambiguity counts as present (the thing is on screen, more than
        // once) so an existence wait succeeds; for a `--gone` wait, ambiguity is
        // likewise "still here", so it keeps waiting — both honest.
        switch Finder.resolve(named: name, under: target.element) {
        case .element, .ambiguous:
            return true
        case .none:
            return false
        case .indexOutOfRange:
            // `wait` passes no --nth locator, so this is unreachable; treat a
            // would-be out-of-range as "not present" (an existence wait keeps
            // polling, a --gone wait sees it as gone) rather than crash.
            return false
        }
    }
}
