import XCTest
@testable import GhostHandsKit

/// Hermetic — the honesty invariants on the M3 outcome structs and the new
/// error messages (no app driven). The cross-cutting invariant: `axAccepted`
/// (dispatch) is NEVER conflated with `verified` (observed effect).
final class M3OutcomeTests: XCTestCase {

    // MARK: ValueOutcome

    func testValueDispatchedButUnverified() {
        // setValue returned true (axAccepted) but the field read back unchanged.
        let o = ValueOutcome(app: "Safari", name: "Search", role: "AXTextField",
                             verb: "set", intended: "hello", axAccepted: true,
                             verified: false, exact: false, valueBefore: "old",
                             valueAfter: "old", evidence: nil)
        XCTAssertTrue(o.axAccepted)      // AX dispatched
        XCTAssertFalse(o.verified)       // but NOT a success — the no-op trap
    }

    func testValueVerifiedExactCarriesEvidence() {
        let o = ValueOutcome(app: "Safari", name: "Search", role: "AXTextField",
                             verb: "typed", intended: "hello", axAccepted: true,
                             verified: true, exact: true, valueBefore: nil,
                             valueAfter: "hello", evidence: "value nil → \"hello\"")
        XCTAssertTrue(o.verified)
        XCTAssertTrue(o.exact)
        XCTAssertEqual(o.evidence, "value nil → \"hello\"")
    }

    // MARK: ActOutcome

    func testActDispatchedButUnverified() {
        // raise: AXRaise accepted but no in-AX observable → dispatched, never verified.
        let o = ActOutcome(app: "TextEdit", name: "Untitled", role: "AXWindow",
                           action: "AXRaise", verbLabel: "act raise", axAccepted: true,
                           verified: false, evidence: nil)
        XCTAssertTrue(o.axAccepted)
        XCTAssertFalse(o.verified)
    }

    func testActVerifiedIncrement() {
        let o = ActOutcome(app: "System Settings", name: "Volume", role: "AXSlider",
                           action: "AXIncrement", verbLabel: "act increment",
                           axAccepted: true, verified: true, evidence: "value 40 → 45",
                           valueBefore: "40", valueAfter: "45")
        XCTAssertTrue(o.verified)
        XCTAssertEqual(o.evidence, "value 40 → 45")
    }

    // MARK: error messages (the one-line honest refuses)

    func testSecureFieldErrorMentionsUnverifiable() {
        let msg = "\(GhostHandsError.secureFieldUnverifiable(name: "Password"))"
        XCTAssertTrue(msg.contains("secure text field"))
        XCTAssertTrue(msg.contains("cannot be verified"))
    }

    func testValueUncoercibleErrorNamesTheControl() {
        let msg = "\(GhostHandsError.valueUncoercible(value: "banana", role: "AXSlider"))"
        XCTAssertTrue(msg.contains("banana"))
        XCTAssertTrue(msg.contains("AXSlider"))
    }

    func testWrongActionErrorListsSupported() {
        let msg = "\(GhostHandsError.wrongActionForControl(name: "Volume", action: "AXIncrement", supported: ["AXPress"]))"
        XCTAssertTrue(msg.contains("AXIncrement"))
        XCTAssertTrue(msg.contains("AXPress"))
        XCTAssertTrue(msg.contains("wrong action"))
    }

    func testUnknownActionListsTheValidSet() {
        let msg = "\(GhostHandsError.unknownAction("frobnicate"))"
        XCTAssertTrue(msg.contains("frobnicate"))
        XCTAssertTrue(msg.contains("increment"))   // the usage list is present
    }
}
