import XCTest
@testable import GhostHandsKit

/// Hermetic — value coercion, the increment/decrement direction verdict, and the
/// friendly→AX action map. All pure (fabricated inputs), no live app. These
/// guard the set-value/act honesty: an uncoercible value REFUSES (nil) rather
/// than guessing a wrong one, and an action that did not move the value in the
/// requested direction is DISPATCHED (honest), never a faked success.
final class ActionVerdictTests: XCTestCase {

    // MARK: ValueCoercion — booleans

    func testCheckboxTruthyWordsCoerceToOne() {
        for raw in ["on", "true", "1", "yes", "checked", "ON", "True"] {
            XCTAssertEqual(ValueCoercion.coerce(raw, role: "AXCheckBox"), .bool(true),
                           "\(raw) should coerce to true")
        }
    }

    func testCheckboxFalsyWordsCoerceToZero() {
        for raw in ["off", "false", "0", "no", "unchecked", "OFF"] {
            XCTAssertEqual(ValueCoercion.coerce(raw, role: "AXCheckBox"), .bool(false),
                           "\(raw) should coerce to false")
        }
    }

    func testCheckboxArbitraryStringIsUncoercible() {
        // A checkbox cannot hold "banana" — REFUSE (nil), never guess.
        XCTAssertNil(ValueCoercion.coerce("banana", role: "AXCheckBox"))
    }

    func testSwitchAndRadioAlsoBoolean() {
        XCTAssertEqual(ValueCoercion.coerce("on", role: "AXSwitch"), .bool(true))
        XCTAssertEqual(ValueCoercion.coerce("off", role: "AXRadioButton"), .bool(false))
    }

    // MARK: ValueCoercion — numerics

    func testSliderNumericCoerces() {
        XCTAssertEqual(ValueCoercion.coerce("45", role: "AXSlider"), .number(45))
        XCTAssertEqual(ValueCoercion.coerce("0.5", role: "AXSlider"), .number(0.5))
    }

    func testSliderNonNumericIsUncoercible() {
        // "banana" for a slider — REFUSE rather than set a wrong (guessed) number.
        XCTAssertNil(ValueCoercion.coerce("banana", role: "AXSlider"))
    }

    func testStepperNumericCoerces() {
        XCTAssertEqual(ValueCoercion.coerce("3", role: "AXStepper"), .number(3))
    }

    // MARK: ValueCoercion — strings / popups

    func testPopupArbitraryStringIsAString() {
        XCTAssertEqual(ValueCoercion.coerce("Large", role: "AXPopUpButton"), .string("Large"))
    }

    func testUnknownRoleBooleanWordStillCoercesToBool() {
        // A toggle exposed as AXMenuButton: "on" is still a boolean intent.
        XCTAssertEqual(ValueCoercion.coerce("on", role: "AXMenuButton"), .bool(true))
    }

    // MARK: ValueCoercion — expectedReadback (what we compare to on read-back)

    func testExpectedReadbackStrings() {
        XCTAssertEqual(ValueCoercion.bool(true).expectedReadback, "1")
        XCTAssertEqual(ValueCoercion.bool(false).expectedReadback, "0")
        XCTAssertEqual(ValueCoercion.number(45).expectedReadback, "45")   // trailing .0 trimmed
        XCTAssertEqual(ValueCoercion.number(0.5).expectedReadback, "0.5")
        XCTAssertEqual(ValueCoercion.string("Large").expectedReadback, "Large")
    }

    // MARK: DirectionVerdict

    func testIncrementUpVerifiedOnMove() {
        guard case let .verified(evidence) =
            DirectionVerdict.decide(before: "40", after: "45", direction: .up) else {
            return XCTFail("a value that increased must verify an increment")
        }
        XCTAssertEqual(evidence, "value 40 → 45")
    }

    func testDecrementDownVerifiedOnMove() {
        guard case .verified = DirectionVerdict.decide(before: "45", after: "40", direction: .down) else {
            return XCTFail("a value that decreased must verify a decrement")
        }
    }

    func testIncrementSaturatedAtBoundIsDispatched() {
        // Increment an already-max slider → no movement → DISPATCHED (honest
        // 'landed but no change'), distinguishable from a rejection.
        XCTAssertEqual(DirectionVerdict.decide(before: "100", after: "100", direction: .up),
                       .dispatched)
    }

    func testDecrementAtZeroIsDispatched() {
        XCTAssertEqual(DirectionVerdict.decide(before: "0", after: "0", direction: .down),
                       .dispatched)
    }

    func testWrongDirectionMoveIsDispatched() {
        // Value moved the WRONG way for the requested action → not verified.
        XCTAssertEqual(DirectionVerdict.decide(before: "40", after: "35", direction: .up),
                       .dispatched)
    }

    func testNonNumericValueCannotProveDirection() {
        // Cannot parse a number → cannot prove a direction → honest DISPATCHED.
        XCTAssertEqual(DirectionVerdict.decide(before: "abc", after: "def", direction: .up),
                       .dispatched)
        XCTAssertEqual(DirectionVerdict.decide(before: nil, after: "5", direction: .up),
                       .dispatched)
    }

    // MARK: ActionName map

    func testFriendlyActionsMapToAXStrings() {
        XCTAssertEqual(ActionName.axAction(for: "open"), "AXOpen")
        XCTAssertEqual(ActionName.axAction(for: "confirm"), "AXConfirm")
        XCTAssertEqual(ActionName.axAction(for: "pick"), "AXPick")
        XCTAssertEqual(ActionName.axAction(for: "show-menu"), "AXShowMenu")
        XCTAssertEqual(ActionName.axAction(for: "showmenu"), "AXShowMenu")
        XCTAssertEqual(ActionName.axAction(for: "cancel"), "AXCancel")
        XCTAssertEqual(ActionName.axAction(for: "raise"), "AXRaise")
        XCTAssertEqual(ActionName.axAction(for: "increment"), "AXIncrement")
        XCTAssertEqual(ActionName.axAction(for: "decrement"), "AXDecrement")
        XCTAssertEqual(ActionName.axAction(for: "INCREMENT"), "AXIncrement")  // case-insensitive
    }

    func testUnknownActionReturnsNil() {
        XCTAssertNil(ActionName.axAction(for: "frobnicate"))
        XCTAssertNil(ActionName.axAction(for: ""))
    }
}
