import ApplicationServices
import AXorcist
import Foundation

/// The outcome of a value-setting verb (`type`, `set-value`) — honest about
/// whether the value was VERIFIED (read back as the intended/changed value) or
/// merely DISPATCHED (AX accepted the set but the read-back showed no change).
///
/// The contract this struct enforces: `axAccepted` is ONLY that `setValue()`
/// returned true (a dispatch). `verified` is the stronger claim that the field
/// READ BACK as changed — it is computed by `ValueVerdict.decide` from the
/// read-back, NEVER from `axAccepted`. This is the structural prevention of the
/// M3 cardinal sin (setValue==true faking success).
public struct ValueOutcome: Sendable, Equatable {
    public let app: String
    public let name: String
    public let role: String
    public let verb: String          // "typed" / "set" — for the report phrasing
    public let intended: String
    public let axAccepted: Bool
    public let verified: Bool
    /// True only on an EXACT read-back match (after == intended). When a verified
    /// change was a normalisation/partial ("JOHN" → "john"), this is false and
    /// the before → after is quoted so the human sees it.
    public let exact: Bool
    public let valueBefore: String?
    public let valueAfter: String?
    public let evidence: String?
    public let witnessName: String?
    public let witnessBefore: String?
    public let witnessAfter: String?

    public init(app: String, name: String, role: String, verb: String,
                intended: String, axAccepted: Bool, verified: Bool, exact: Bool,
                valueBefore: String?, valueAfter: String?, evidence: String?,
                witnessName: String? = nil, witnessBefore: String? = nil,
                witnessAfter: String? = nil) {
        self.app = app
        self.name = name
        self.role = role
        self.verb = verb
        self.intended = intended
        self.axAccepted = axAccepted
        self.verified = verified
        self.exact = exact
        self.valueBefore = valueBefore
        self.valueAfter = valueAfter
        self.evidence = evidence
        self.witnessName = witnessName
        self.witnessBefore = witnessBefore
        self.witnessAfter = witnessAfter
    }
}

extension GhostHands {
    /// `type "<text>" "<field-name>" <app>` — set a TEXT-ENTRY control's value
    /// via AX, then read it back to verify. Cursor-less, no synthetic keystrokes.
    ///
    /// Honesty contract:
    /// - refuses (throws) when the field is not found / ambiguous / not a
    ///   text-entry role / a SECURE field (value unreadable → unverifiable) /
    ///   setValue rejected by AX,
    /// - VERIFIED only when the read-back shows the field now holds (or moved
    ///   toward) the text — never off the setValue boolean,
    /// - DISPATCHED-UNVERIFIED (returned, not thrown) when AX accepted the set
    ///   but the value read back unchanged: the no-op trap, reported plainly.
    @MainActor
    public static func type(text: String, field: String, appSpec: String,
                            locator: LocatorSpec = .none,
                            settle: TimeInterval = 0.15) throws -> ValueOutcome {
        try setValueImpl(rawValue: text, name: field, appSpec: appSpec,
                         verb: "typed", accept: Finder.isTextEntry,
                         coerceForRole: false, locator: locator, settle: settle)
    }

    /// `set-value "<value>" "<control-name>" <app>` — set a non-text control
    /// (checkbox/switch/radio/slider/stepper/popup/combo) via AX, then read back.
    /// The value is type-COERCED to the control (on/off → 1/0, numeric for
    /// sliders, string for popups); an uncoercible request REFUSES rather than
    /// setting a wrong value.
    @MainActor
    public static func setValue(value: String, control: String, appSpec: String,
                                locator: LocatorSpec = .none,
                                settle: TimeInterval = 0.15) throws -> ValueOutcome {
        try setValueImpl(rawValue: value, name: control, appSpec: appSpec,
                         verb: "set", accept: Finder.isSettable,
                         coerceForRole: true, locator: locator, settle: settle)
    }

    /// The shared resolve → set → fresh-read-back → verdict core for both verbs.
    /// `coerceForRole` distinguishes `type` (always a string set) from
    /// `set-value` (coerces on/off → bool, numeric for sliders, etc.).
    @MainActor
    static func setValueImpl(rawValue: String, name: String, appSpec: String,
                             verb: String, accept: (ElementFacts) -> Bool,
                             coerceForRole: Bool, locator: LocatorSpec = .none,
                             settle: TimeInterval) throws -> ValueOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        let element: Element
        let facts: ElementFacts
        switch Finder.resolve(named: name, under: target.element, accept: accept,
                              locator: locator) {
        case let .element(found, foundFacts):
            element = found
            facts = foundFacts
        case let .ambiguous(candidates):
            throw GhostHandsError.ambiguousMatch(name: name, candidates: candidates)
        case let .indexOutOfRange(requested, count):
            throw GhostHandsError.locatorIndexOutOfRange(name: name, requested: requested, count: count)
        case .none:
            throw GhostHandsError.elementNotFound(name: name, app: target.name)
        }

        let role = facts.role ?? "AXUnknown"

        // SECURE-FIELD honesty gate: a password field returns no readable value,
        // so a successful set can NEVER be verified. REFUSE by default rather
        // than claim an unverifiable success (or silently set a password).
        if facts.isSecureTextField {
            throw GhostHandsError.secureFieldUnverifiable(name: name)
        }

        // Coerce the value to the control's type (set-value only). The string we
        // SET and the string we EXPECT to read back may differ (bool → "1").
        let setArg: Any
        let intendedReadback: String
        if coerceForRole {
            guard let coerced = ValueCoercion.coerce(rawValue, role: facts.role) else {
                throw GhostHandsError.valueUncoercible(value: rawValue, role: role)
            }
            switch coerced {
            case let .bool(b): setArg = b
            case let .number(n): setArg = NSNumber(value: n)
            case let .string(s): setArg = s
            }
            intendedReadback = coerced.expectedReadback
        } else {
            setArg = rawValue
            intendedReadback = rawValue
        }

        let before = facts.value
        let stableIdentity = NameMatch.stableIdentityKey(facts)

        // Capture witnesses BEFORE the set (scoped to the enclosing window).
        let probe = EffectProbe(pid: target.pid, settle: settle)
        let witnessBefore = probe.captureBefore(of: element)

        // AUTO-FOCUS (best-effort, `type` only): focus the field BEFORE writing
        // its value so the field is actually ACTIVE — a later Enter/submit then
        // lands on it. This is purely a side-effect to make a subsequent key
        // dispatch work; it does NOT enter the honesty verdict. If focus is not
        // confirmed (AXFocused unsettable / reads back false), we STILL proceed to
        // set the value: `type` is verified by the value read-back below, never by
        // focus, so we must never refuse the type just because focus was
        // unconfirmed. Scoped to `type` (coerceForRole==false) — `set-value`
        // mutates checkboxes/sliders/popups that need no text-entry focus.
        if !coerceForRole {
            _ = setFocused(element: element, facts: facts, pid: target.pid, settle: settle)
        }

        // DISPATCH. setValue==false means AX rejected outright → REFUSE. A `true`
        // here is ONLY a dispatch — it is the read-back below, not this boolean,
        // that may promote the result to VERIFIED.
        guard element.setValue(setArg, forAttribute: AXAttributeNames.kAXValueAttribute) else {
            throw GhostHandsError.actionRejected(name: name, action: "AXValue set")
        }

        if settle > 0 { Thread.sleep(forTimeInterval: settle) }

        // Read the SAME control back by stable identity off a FRESH tree. A cold
        // first read can miss; readbackSelf confirms before concluding absent.
        let (readback, readbackRoot) =
            probe.readbackSelf(stableIdentity: stableIdentity, named: name, accept: accept)
        let after: String?
        switch readback {
        case let .present(value): after = value
        case .disabled, .goneConfirmed, .goneUnconfirmed: after = nil
        }

        // Witness fallback for opaque controls (value not on the control itself).
        let witnessDiff = probe.diff(witnessBefore, readbackRoot: readbackRoot)

        let verdict = ValueVerdict.decide(before: before, after: after,
                                          intended: intendedReadback,
                                          witnessDiff: witnessDiff)

        switch verdict {
        case let .verified(evidence, exact, witness):
            return ValueOutcome(app: target.name, name: name, role: role, verb: verb,
                                intended: rawValue, axAccepted: true, verified: true,
                                exact: exact, valueBefore: before, valueAfter: after,
                                evidence: evidence, witnessName: witness?.name,
                                witnessBefore: witness?.before, witnessAfter: witness?.after)
        case .dispatched:
            // AX accepted but no observed change — the no-op trap. We do NOT
            // throw here: the dispatch genuinely happened, and the CLI reports it
            // plainly as dispatched-unverified (exit 0, never a success claim).
            return ValueOutcome(app: target.name, name: name, role: role, verb: verb,
                                intended: rawValue, axAccepted: true, verified: false,
                                exact: false, valueBefore: before, valueAfter: after,
                                evidence: nil)
        }
    }
}
