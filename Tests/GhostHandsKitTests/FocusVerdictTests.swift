import XCTest
@testable import GhostHandsKit

/// Hermetic — the honesty surface for `focus`, over a FABRICATED AXFocused
/// read-back Bool (no live app). The single invariant under test: focus is
/// VERIFIED ONLY when AXFocused reads back `true`; an accepted-but-not-true
/// read-back (`false`, or an unreadable `nil`) is NEVER verified — the
/// structural prevention of claiming a focus we cannot observe. The (here,
/// implicit) setValue boolean is intentionally absent: the decider never sees it.
final class FocusVerdictTests: XCTestCase {
    private func decide(_ focusedAfter: Bool?) -> FocusVerdict.Result {
        FocusVerdict.decide(focusedAfter: focusedAfter)
    }

    // MARK: verified — AXFocused read back true

    func testFocusedReadbackTrueIsVerified() {
        guard case let .verified(evidence) = decide(true) else {
            return XCTFail("AXFocused read back true must verify")
        }
        XCTAssertEqual(evidence, "AXFocused → true")
    }

    // MARK: dispatched — accepted but not observed focused

    func testFocusedReadbackFalseIsDispatchedNeverVerified() {
        // AX accepted the AXFocused set (the caller already checked setValue==true)
        // but the control reads back NOT focused — the no-op trap. MUST dispatch.
        XCTAssertEqual(decide(false), .dispatched)
    }

    func testFocusedReadbackNilIsDispatched() {
        // AXFocused is unreadable / unsettable on this control — we cannot witness
        // focus, so we must NEVER claim it. Demote to dispatched (the safe way).
        XCTAssertEqual(decide(nil), .dispatched)
    }

    // MARK: the cardinal-sin fence — only `true` carries a claim

    func testOnlyTrueVerifies() {
        // Exhaustive over the three observable read-backs: exactly one verifies.
        XCTAssertNotEqual(decide(true), .dispatched)   // true → verified
        XCTAssertEqual(decide(false), .dispatched)     // false → dispatched
        XCTAssertEqual(decide(nil), .dispatched)       // nil → dispatched
    }

    // MARK: the FocusOutcome struct honesty invariant (dispatch ≠ verified)

    func testFocusOutcomeAcceptedButUnverified() {
        // setValue returned true (axAccepted) but AXFocused read back false.
        let o = FocusOutcome(app: "Safari", name: "Search", role: "AXTextField",
                             axAccepted: true, verified: false, focusedAfter: false,
                             evidence: nil)
        XCTAssertTrue(o.axAccepted)      // AX dispatched the focus set
        XCTAssertFalse(o.verified)       // but NOT a success — focus not observed
    }

    func testFocusOutcomeVerifiedCarriesEvidence() {
        let o = FocusOutcome(app: "Safari", name: "Search", role: "AXTextField",
                             axAccepted: true, verified: true, focusedAfter: true,
                             evidence: "AXFocused → true")
        XCTAssertTrue(o.verified)
        XCTAssertEqual(o.focusedAfter, true)
        XCTAssertEqual(o.evidence, "AXFocused → true")
    }
}
