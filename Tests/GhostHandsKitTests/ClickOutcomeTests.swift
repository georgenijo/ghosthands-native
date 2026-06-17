import XCTest
@testable import GhostHandsKit

/// Hermetic — the honesty verdict logic on a `ClickOutcome` (no app driven).
final class ClickOutcomeTests: XCTestCase {
    func testValueChangedIsEvidence() {
        let o = ClickOutcome(app: "Calc", name: "1", role: "AXButton",
                             axAccepted: true, valueBefore: "0", valueAfter: "1")
        XCTAssertTrue(o.valueChanged)
        XCTAssertTrue(o.landed)
    }

    func testValueUnchanged() {
        let o = ClickOutcome(app: "Calc", name: "x", role: "AXButton",
                             axAccepted: true, valueBefore: "5", valueAfter: "5")
        XCTAssertFalse(o.valueChanged)
    }

    func testLandedReflectsAXAcceptedOnly() {
        // landed is the AX-accepted floor; it must never be fabricated.
        let rejected = ClickOutcome(app: "A", name: "n", role: "r",
                                    axAccepted: false, valueBefore: nil, valueAfter: nil)
        XCTAssertFalse(rejected.landed)
    }
}
