import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE assertion decider over FABRICATED observations (no live
/// app driven). The contract under test: a verdict is PASS *only* on the
/// OBSERVED condition, and every FAIL renders the ACTUAL vs the EXPECTED (a real
/// machine-checkable assertion, never a default green and never a bare "failed").
/// The FAIL-vs-REFUSE split (a refuse is a thrown error in the live layer) is
/// covered separately — this decider only ever emits PASS or FAIL.
final class AssertVerdictTests: XCTestCase {
    private typealias Obs = AssertVerdict.Observation

    private func decide(_ kind: AssertVerdict.Kind, name: String = "X",
                        _ observed: Obs) -> AssertVerdict.Verdict {
        AssertVerdict.decide(kind, name: name, observed: observed)
    }

    // MARK: exists

    func testExistsPassesWhenPresent() {
        let v = decide(.exists, .present())
        XCTAssertTrue(v.passed)
        XCTAssertTrue(v.message.hasPrefix("PASS:"))
    }

    func testExistsFailsWhenAbsent() {
        let v = decide(.exists, .missing)
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.message.hasPrefix("FAIL:"))
        // The actual (0 matches) is stated.
        XCTAssertTrue(v.message.contains("found 0"))
    }

    func testExistsPassesEvenWithSeveralMatches() {
        // Presence is count > 0; multiple matches still EXIST.
        let v = decide(.exists, .present(count: 3))
        XCTAssertTrue(v.passed)
        XCTAssertTrue(v.message.contains("3 matches"))
    }

    // MARK: absent

    func testAbsentPassesWhenMissing() {
        let v = decide(.absent, .missing)
        XCTAssertTrue(v.passed)
        XCTAssertTrue(v.message.contains("0 matches"))
    }

    func testAbsentFailsWhenPresentAndReportsCount() {
        // The honesty point: asserting absence of a present control FAILS and the
        // ACTUAL count is reported (not a bare "failed").
        let v = decide(.absent, .present(count: 2))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.message.hasPrefix("FAIL:"))
        XCTAssertTrue(v.message.contains("found 2"))
    }

    func testAbsentFailsSingleMatchSingularPhrasing() {
        let v = decide(.absent, .present(count: 1))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.message.contains("found 1 match"))
        XCTAssertFalse(v.message.contains("1 matches"))   // singular
    }

    // MARK: value ==

    func testValueEqualsPassesOnExactMatch() {
        let v = decide(.valueEquals("789"), .present(value: "789"))
        XCTAssertTrue(v.passed)
        XCTAssertTrue(v.message.contains("\"789\""))
    }

    func testValueEqualsFailsAndReportsActualVsExpected() {
        // The cardinal honesty case: a mismatch is a FAIL that prints BOTH the
        // actual and the expected, so a harness sees exactly what was wrong.
        let v = decide(.valueEquals("789"), .present(value: "123"))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.message.hasPrefix("FAIL:"))
        XCTAssertTrue(v.message.contains("\"123\""))   // actual
        XCTAssertTrue(v.message.contains("\"789\""))   // expected
    }

    func testValueEqualsEmptyMatchesEmpty() {
        // An empty read-back and an expected "" are the same observable (blank).
        XCTAssertTrue(decide(.valueEquals(""), .present(value: nil)).passed)
        XCTAssertTrue(decide(.valueEquals(""), .present(value: "")).passed)
    }

    func testValueEqualsEmptyVsNonEmptyFails() {
        // A blank control where a value was expected FAILS, quoting "empty" as the
        // actual (never the literal "nil", never a fabricated value).
        let v = decide(.valueEquals("hi"), .present(value: nil))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.message.contains("empty"))
        XCTAssertTrue(v.message.contains("\"hi\""))
    }

    func testValueEqualsNonEmptyExpectedEmptyFails() {
        // Symmetric: expected empty, got a value → FAIL with the actual quoted.
        let v = decide(.valueEquals(""), .present(value: "x"))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.message.contains("\"x\""))
    }

    func testValueEqualsIsExactNotFuzzy() {
        // An assertion is a HARD equality — a substring / "moved toward" is a FAIL,
        // unlike the type/set-value verdict which promotes a partial commit.
        XCTAssertFalse(decide(.valueEquals("5"), .present(value: "$5.00")).passed)
        XCTAssertFalse(decide(.valueEquals("JOHN"), .present(value: "john")).passed)
    }

    // MARK: count ==

    func testCountEqualsPasses() {
        XCTAssertTrue(decide(.countEquals(2), .present(count: 2)).passed)
    }

    func testCountEqualsZeroPassesOnMissing() {
        // assert count 0 is the dual of assert absent — PASS on no matches.
        XCTAssertTrue(decide(.countEquals(0), .missing).passed)
    }

    func testCountEqualsFailsAndReportsActual() {
        let v = decide(.countEquals(1), .present(count: 3))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.message.hasPrefix("FAIL:"))
        XCTAssertTrue(v.message.contains("count is 3"))
        XCTAssertTrue(v.message.contains("expected 1"))
    }

    func testCountEqualsZeroFailsWhenPresent() {
        let v = decide(.countEquals(0), .present(count: 2))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.message.contains("count is 2"))
    }

    // MARK: the name is always echoed (the subject is explicit)

    func testNameIsQuotedInEveryMessage() {
        let pass = decide(.exists, name: "Save", .present())
        let fail = decide(.exists, name: "Save", .missing)
        XCTAssertTrue(pass.message.contains("\"Save\""))
        XCTAssertTrue(fail.message.contains("\"Save\""))
    }

    // MARK: Verdict accessors

    func testVerdictMessageAndPassedAgree() {
        let p = AssertVerdict.Verdict.pass("ok")
        let f = AssertVerdict.Verdict.fail("no")
        XCTAssertTrue(p.passed); XCTAssertEqual(p.message, "ok")
        XCTAssertFalse(f.passed); XCTAssertEqual(f.message, "no")
    }

    // MARK: Observation convenience

    func testObservationPresentFlag() {
        XCTAssertTrue(Obs.present().present)
        XCTAssertTrue(Obs.present(count: 5).present)
        XCTAssertFalse(Obs.missing.present)
        XCTAssertFalse(Obs(count: 0, value: nil).present)
    }

    // MARK: retry-on-empty policy (pure)

    func testRetryOnEmptyOnlyForPresenceAssertions() {
        // A presence-shaped assertion re-reads on an empty first read; an
        // absence-shaped one does not (an empty read is already the expected
        // state). This is the pure policy that gates the single live retry.
        XCTAssertTrue(GhostHands.retryOnEmpty(.exists))
        XCTAssertTrue(GhostHands.retryOnEmpty(.valueEquals("x")))
        XCTAssertTrue(GhostHands.retryOnEmpty(.countEquals(2)))
        XCTAssertFalse(GhostHands.retryOnEmpty(.absent))
        XCTAssertFalse(GhostHands.retryOnEmpty(.countEquals(0)))
    }
}
