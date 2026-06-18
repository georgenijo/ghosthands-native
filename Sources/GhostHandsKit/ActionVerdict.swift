import Foundation

/// Pure value-coercion for `set-value` — turns a human string into the AX value
/// a control expects, or REFUSES (returns nil) when the request cannot be
/// honestly coerced. A nil result means "uncoercible → REFUSE", never "guess a
/// default": guessing a wrong value and then SETTING it would be the very
/// dishonesty this project exists to avoid.
public enum ValueCoercion: Sendable, Equatable {
    /// A boolean control state (checkbox / switch / radio) → AXValue 0 or 1.
    case bool(Bool)
    /// A numeric control value (slider / stepper) → AXValue Double.
    case number(Double)
    /// A string selection / text (popup title, combo box) → AXValue String.
    case string(String)

    /// The string set of role names that read/write a 0/1 boolean AXValue.
    public static let booleanRoles: Set<String> = [
        "AXCheckBox", "AXSwitch", "AXToggle", "AXRadioButton", "AXDisclosureTriangle",
    ]
    /// Roles whose AXValue is numeric (a slider position, a stepper count).
    public static let numericRoles: Set<String> = [
        "AXSlider", "AXStepper", "AXIncrementor", "AXValueIndicator",
    ]

    private static let truthy: Set<String> = ["on", "true", "1", "yes", "checked", "enabled"]
    private static let falsy: Set<String> = ["off", "false", "0", "no", "unchecked", "disabled"]

    /// Coerce `raw` for a control of `role`. Returns nil when the value cannot be
    /// honestly represented for that control (e.g. "banana" for a slider) — the
    /// caller turns nil into a `.valueUncoercible` REFUSE.
    public static func coerce(_ raw: String, role: String?) -> ValueCoercion? {
        let lowered = raw.lowercased()
        if let role, booleanRoles.contains(role) {
            if truthy.contains(lowered) { return .bool(true) }
            if falsy.contains(lowered) { return .bool(false) }
            return nil   // a checkbox cannot hold an arbitrary string — refuse
        }
        if let role, numericRoles.contains(role) {
            if let d = Double(raw) { return .number(d) }
            return nil   // "banana" for a slider — refuse, never guess a number
        }
        // Popups / combo boxes / unknown settable roles: a boolean word still
        // coerces to a boolean (some toggles expose as AXMenuButton); otherwise
        // it is a string selection / free text.
        if truthy.contains(lowered) { return .bool(true) }
        if falsy.contains(lowered) { return .bool(false) }
        return .string(raw)
    }

    /// The string we expect the control's AXValue to read back as, for the
    /// VERIFIED comparison. A boolean reads back as the NSNumber "0"/"1"; a
    /// number reads back via NSNumber.stringValue (drops a trailing ".0"); a
    /// string reads back verbatim.
    public var expectedReadback: String {
        switch self {
        case let .bool(b): return b ? "1" : "0"
        case let .number(n): return NSNumber(value: n).stringValue
        case let .string(s): return s
        }
    }
}

/// Pure verdict for `act increment` / `act decrement` — VERIFIED only when the
/// numeric read-back moved in the EXPECTED direction. A value that did not move
/// (already at the min/max bound, or the app ignored the step) is DISPATCHED —
/// an honest "the action landed but the value did not change", never a failure
/// and never a faked success.
public enum DirectionVerdict {
    public enum Direction: Sendable { case up, down }

    public enum Result: Sendable, Equatable {
        /// The value moved in the requested direction — quote before → after.
        case verified(evidence: String)
        /// No numeric movement observed (saturated at a bound, or no-op).
        case dispatched
    }

    /// Decide from the numeric read-back. `before`/`after` are the AXValue
    /// strings (parsed to Double); if either is unparseable we cannot prove
    /// direction, so we honestly DISPATCH rather than guess.
    public static func decide(before: String?, after: String?,
                              direction: Direction) -> Result {
        guard let b = before.flatMap(Double.init),
              let a = after.flatMap(Double.init) else {
            return .dispatched   // not numeric → cannot prove a direction → honest dispatch
        }
        let moved: Bool
        switch direction {
        case .up: moved = a > b
        case .down: moved = a < b
        }
        if moved {
            return .verified(evidence: "value \(trim(b)) → \(trim(a))")
        }
        return .dispatched       // saturated / no-op — honest, distinguishable from a reject
    }

    /// Render a Double without a gratuitous trailing ".0" (40.0 → "40").
    static func trim(_ d: Double) -> String { NSNumber(value: d).stringValue }
}

/// The friendly-name → AX-action-string map for the `act` verb. Pure and total:
/// an unknown action returns nil so the caller emits the usage-class
/// `.unknownAction` REFUSE (exit 2) rather than throwing at the AX layer.
public enum ActionName {
    /// (friendlyName) → AX action string. The eight verbs the contract exposes.
    public static func axAction(for friendly: String) -> String? {
        switch friendly.lowercased() {
        case "open": return "AXOpen"
        case "confirm": return "AXConfirm"
        case "pick": return "AXPick"
        case "show-menu", "showmenu": return "AXShowMenu"
        case "cancel": return "AXCancel"
        case "raise": return "AXRaise"
        case "increment": return "AXIncrement"
        case "decrement": return "AXDecrement"
        default: return nil
        }
    }

    /// The canonical usage string of accepted actions (for the REFUSE message).
    public static let known = "open|confirm|pick|show-menu|cancel|raise|increment|decrement"
}
