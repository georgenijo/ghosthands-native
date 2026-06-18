import XCTest
@testable import GhostHandsKit

/// Hermetic — the honesty surface for `wait`, over FABRICATED observation
/// sequences (no live app, no real clock). The cardinal invariant under test: a
/// wait is `.met` ONLY when an in-time sample is OBSERVED to satisfy the
/// condition; a sequence that never satisfies it — no matter how many polls —
/// MUST evaluate to `.timedOut` (a refuse), never a fabricated success. The live
/// poll loop (which calls Finder.resolve) is the impure half and is NOT tested
/// here; every DECISION it delegates to is tested here.
final class WaitVerdictTests: XCTestCase {
    private typealias Obs = WaitVerdict.Observation

    // MARK: decide(found:wantGone:) — the per-poll sense

    func testDecideExistenceWait() {
        // Without --gone we wait for existence: found → met, absent → not yet.
        XCTAssertEqual(WaitVerdict.decide(found: true, wantGone: false), .met)
        XCTAssertEqual(WaitVerdict.decide(found: false, wantGone: false), .notYet)
    }

    func testDecideGoneWaitInvertsTheSense() {
        // With --gone we wait for ABSENCE: absent → met, found → not yet.
        XCTAssertEqual(WaitVerdict.decide(found: false, wantGone: true), .met)
        XCTAssertEqual(WaitVerdict.decide(found: true, wantGone: true), .notYet)
    }

    func testDecideIsTheExactXOR() {
        // Exhaustive over the 4 (found × wantGone) cases — exactly the cases where
        // the OBSERVED presence matches what we are waiting for are `.met`.
        XCTAssertEqual(WaitVerdict.decide(found: true, wantGone: false), .met)
        XCTAssertEqual(WaitVerdict.decide(found: false, wantGone: true), .met)
        XCTAssertEqual(WaitVerdict.decide(found: false, wantGone: false), .notYet)
        XCTAssertEqual(WaitVerdict.decide(found: true, wantGone: true), .notYet)
    }

    // MARK: evaluate — existence waits

    func testElementPresentOnFirstPollMetImmediately() {
        let obs = [Obs(elapsed: 0.0, found: true)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 5, wantGone: false),
                       .met(elapsed: 0.0, polls: 1))
    }

    func testElementAppearsAfterSeveralPollsMetAtThatSample() {
        // Absent, absent, then present on the 3rd poll (at 0.30s) → met-at the 3rd.
        let obs = [Obs(elapsed: 0.0, found: false),
                   Obs(elapsed: 0.15, found: false),
                   Obs(elapsed: 0.30, found: true)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 5, wantGone: false),
                       .met(elapsed: 0.30, polls: 3))
    }

    func testFirstSatisfyingSampleWinsNotALaterOne() {
        // Present from the 2nd poll onward — the FIRST satisfying sample is the
        // met-at, never a later one (we stop the instant the condition holds).
        let obs = [Obs(elapsed: 0.0, found: false),
                   Obs(elapsed: 0.2, found: true),
                   Obs(elapsed: 0.4, found: true)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 5, wantGone: false),
                       .met(elapsed: 0.2, polls: 2))
    }

    func testNeverAppearsTimesOut() {
        // Absent on every poll up to the deadline → REFUSE (timed out), carrying
        // the last sample's elapsed and the total poll count. NEVER a met.
        let obs = [Obs(elapsed: 0.0, found: false),
                   Obs(elapsed: 0.15, found: false),
                   Obs(elapsed: 0.30, found: false)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 0.30, wantGone: false),
                       .timedOut(elapsed: 0.30, polls: 3))
    }

    func testEmptySequenceTimesOutWithZeroElapsed() {
        // No samples at all → timed out, 0 elapsed, 0 polls — never a fake met.
        XCTAssertEqual(WaitVerdict.evaluate(observations: [], deadline: 5, wantGone: false),
                       .timedOut(elapsed: 0, polls: 0))
    }

    // MARK: evaluate — --gone waits

    func testElementGoneAfterSeveralPolls() {
        // Present, present, then absent on the 3rd poll → met (gone) at the 3rd.
        let obs = [Obs(elapsed: 0.0, found: true),
                   Obs(elapsed: 0.15, found: true),
                   Obs(elapsed: 0.30, found: false)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 5, wantGone: true),
                       .met(elapsed: 0.30, polls: 3))
    }

    func testElementNeverLeavesTimesOutOnGoneWait() {
        // Still present on every poll for a --gone wait → REFUSE, never a met.
        let obs = [Obs(elapsed: 0.0, found: true),
                   Obs(elapsed: 0.2, found: true)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 0.2, wantGone: true),
                       .timedOut(elapsed: 0.2, polls: 2))
    }

    func testAlreadyGoneOnFirstPollMetImmediately() {
        // For a --gone wait, an already-absent element succeeds on the 1st poll.
        let obs = [Obs(elapsed: 0.0, found: false)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 5, wantGone: true),
                       .met(elapsed: 0.0, polls: 1))
    }

    // MARK: the deadline fence — a post-deadline satisfying sample is TOO LATE

    func testSampleAfterDeadlineCannotFlipATimeoutIntoSuccess() {
        // The element appears, but ONLY in a sample taken AFTER the deadline
        // (0.6s > 0.5s). The wall clock already expired, so this is a TIMEOUT, not
        // a (dishonest) met — the deadline is the real bound.
        let obs = [Obs(elapsed: 0.0, found: false),
                   Obs(elapsed: 0.6, found: true)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 0.5, wantGone: false),
                       .timedOut(elapsed: 0.6, polls: 2))
    }

    func testSampleExactlyAtDeadlineStillCounts() {
        // A sample taken exactly AT the deadline (<=) is still in time → met.
        let obs = [Obs(elapsed: 0.0, found: false),
                   Obs(elapsed: 0.5, found: true)]
        XCTAssertEqual(WaitVerdict.evaluate(observations: obs, deadline: 0.5, wantGone: false),
                       .met(elapsed: 0.5, polls: 2))
    }

    // MARK: the cardinal-sin fence — many polls NEVER fabricate a met

    func testManyPollsThatNeverMeetStillTimeOut() {
        // 50 polls, every one absent → still a refuse. Poll count is not success.
        let obs = (0..<50).map { Obs(elapsed: Double($0) * 0.1, found: false) }
        let out = WaitVerdict.evaluate(observations: obs, deadline: 100, wantGone: false)
        if case .met = out { XCTFail("a never-satisfied wait must NEVER report met") }
        XCTAssertEqual(out, .timedOut(elapsed: 4.9, polls: 50))
    }

    // MARK: the WaitOutcome struct + error honesty

    func testWaitOutcomeCarriesObservedEvidence() {
        let o = WaitOutcome(app: "TextEdit", name: "Save", wantedGone: false,
                            elapsed: 0.42, polls: 3)
        XCTAssertEqual(o.polls, 3)
        XCTAssertEqual(o.elapsed, 0.42, accuracy: 1e-9)
        XCTAssertFalse(o.wantedGone)
    }

    func testWaitTimeoutErrorMentionsTheConditionAndRefusal() {
        let appear = "\(GhostHandsError.waitTimeout(name: "Login", app: "MyApp", wantedGone: false, seconds: 5))"
        XCTAssertTrue(appear.contains("Login"))
        XCTAssertTrue(appear.contains("to appear"))
        XCTAssertTrue(appear.contains("timed out"))
        XCTAssertTrue(appear.contains("never observed"))

        let gone = "\(GhostHandsError.waitTimeout(name: "Spinner", app: "Safari", wantedGone: true, seconds: 10))"
        XCTAssertTrue(gone.contains("to disappear"))
        XCTAssertTrue(gone.contains("10s"))
    }
}
