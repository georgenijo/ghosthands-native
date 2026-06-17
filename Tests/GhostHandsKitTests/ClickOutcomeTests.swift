import XCTest
@testable import GhostHandsKit

/// Hermetic — the honesty verdict logic on a `ClickOutcome` (no app driven).
/// The key invariant: `landed` (AX dispatched) must never be conflated with
/// `verified` (effect observed).
final class ClickOutcomeTests: XCTestCase {
    func testVerifiedValueChangeIsEvidence() {
        let o = ClickOutcome(app: "X", name: "Enable", role: "AXCheckBox",
                             axAccepted: true, verified: true, evidence: "value 0 → 1",
                             valueBefore: "0", valueAfter: "1")
        XCTAssertTrue(o.verified)
        XCTAssertTrue(o.valueChanged)
        XCTAssertTrue(o.landed)
    }

    func testDispatchedButUnverified() {
        // A plain button: AX accepted the press, but no observable change off
        // the element itself. Honesty: landed (dispatched) yes, verified no.
        let o = ClickOutcome(app: "Calc", name: "7", role: "AXButton",
                             axAccepted: true, verified: false, evidence: nil,
                             valueBefore: nil, valueAfter: nil)
        XCTAssertFalse(o.verified)
        XCTAssertTrue(o.landed)
    }

    func testTargetGoneCountsAsVerified() {
        let o = ClickOutcome(app: "Calc", name: "All Clear", role: "AXButton",
                             axAccepted: true, verified: true,
                             evidence: "target no longer present after press",
                             valueBefore: nil, valueAfter: nil)
        XCTAssertTrue(o.verified)
    }
}
