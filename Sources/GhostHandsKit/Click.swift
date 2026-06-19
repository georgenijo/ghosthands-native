import AppKit
import ApplicationServices
import AXorcist
import Foundation

/// The outcome of a click — carries world-evidence, and is honest about its
/// strength. `axAccepted` is only that the AX layer *dispatched* the action
/// (`press()` returned success). `verified` is the stronger claim that the
/// world was *observed* to change — a value flip, or the target no longer
/// matching after the press. For a plain button (no `AXValue`, still present
/// afterwards) we can dispatch but cannot verify the effect from the element
/// alone, and we say so rather than implying success.
public struct ClickOutcome: Sendable, Equatable {
    public let app: String
    public let name: String
    public let role: String
    public let axAccepted: Bool
    public let verified: Bool
    public let evidence: String?
    public let valueBefore: String?
    public let valueAfter: String?
    /// When the VERIFIED claim rests on a sibling (the M2 effect-witness path),
    /// this names which value-bearing element changed and its before → after,
    /// so the claim is independently auditable — never a bare "success:true".
    public let witnessName: String?
    public let witnessBefore: String?
    public let witnessAfter: String?

    public init(app: String, name: String, role: String, axAccepted: Bool,
                verified: Bool, evidence: String?, valueBefore: String?,
                valueAfter: String?, witnessName: String? = nil,
                witnessBefore: String? = nil, witnessAfter: String? = nil) {
        self.app = app
        self.name = name
        self.role = role
        self.axAccepted = axAccepted
        self.verified = verified
        self.evidence = evidence
        self.valueBefore = valueBefore
        self.valueAfter = valueAfter
        self.witnessName = witnessName
        self.witnessBefore = witnessBefore
        self.witnessAfter = witnessAfter
    }

    public var valueChanged: Bool { valueBefore != valueAfter }
    /// The AX layer accepted the dispatch. NOT proof of effect — see `verified`.
    public var landed: Bool { axAccepted }
}

/// The pure verdict for a click — promotes a press to VERIFIED when the pressed
/// element's OWN value changed, OR it became disabled, OR it is CONFIRMED gone
/// (absent across a settle-retry — a single miss is NOT proof), OR exactly one
/// scoped witness changed. Kept pure (no AX) so the false-positive scoping is
/// hermetically unit-testable. Inputs are the read-back facts; output is the
/// honest verdict.
public enum ClickVerdict {
    /// The structural state of the pressed control on read-back, distilled from
    /// AX so the verdict stays pure. `presentValue` carries the CURRENT value of
    /// a still-present control (for the value-flip check); the absent/disabled
    /// cases carry no value.
    public enum SelfReadback: Sendable, Equatable {
        /// Still present and pressable on read-back; `value` is its value now.
        case present(value: String?)
        /// Found by identity but now reports disabled — a real observed change.
        case disabled
        /// CONFIRMED absent: not found across the settle-retry (two reads). Only
        /// this — never a single miss — may stand as structural evidence.
        case goneConfirmed
        /// Missed on read-back but NOT corroborated by a second read. Structurally
        /// identical to a flaky/cold read, so it is NOT evidence on its own — we
        /// fall through to the witness diff and otherwise under-claim.
        case goneUnconfirmed
    }

    public enum Result: Sendable, Equatable {
        /// Observed change. `evidence` is the human string; `witness` is set
        /// only when the proof came from a sibling (name, before, after).
        case verified(evidence: String, witness: (name: String, before: String?, after: String?)?)
        /// AX accepted but nothing observable changed — honest under-claim.
        case dispatched

        public static func == (lhs: Result, rhs: Result) -> Bool {
            switch (lhs, rhs) {
            case let (.verified(e1, w1), .verified(e2, w2)):
                return e1 == e2 && w1?.name == w2?.name
                    && w1?.before == w2?.before && w1?.after == w2?.after
            case (.dispatched, .dispatched): return true
            default: return false
            }
        }
    }

    /// Decide the verdict from honest structural facts.
    ///
    /// Order of self-evidence (each is an OBSERVED change of the pressed control):
    /// 1. value flip (present, new value ≠ old) — quote before → after,
    /// 2. now disabled — the press disabled the control (a real state change),
    /// 3. CONFIRMED gone — absent across two reads (a single miss is rejected as
    ///    indistinguishable from a flaky/cold post-press read).
    /// Only if the pressed element yields NO self-evidence do we consult the
    /// witness diff; an `.ambiguous` (2+ changed) diff stays DISPATCHED. An
    /// UNCONFIRMED miss is never self-evidence — it can only ride on a witness.
    public static func decide(selfBefore: String?, readback: SelfReadback,
                              witnessDiff: WitnessMatch.Verdict) -> Result {
        switch readback {
        case let .present(value):
            if selfBefore != value {
                return .verified(evidence: "value \(selfBefore ?? "nil") → \(value ?? "nil")",
                                 witness: nil)
            }
        case .disabled:
            return .verified(evidence: "target now disabled after press", witness: nil)
        case .goneConfirmed:
            return .verified(evidence: "target no longer present after press (confirmed on re-read)",
                             witness: nil)
        case .goneUnconfirmed:
            break  // a single missed read is not proof — fall through to the witness
        }
        if case let .changed(name, before, after) = witnessDiff {
            return .verified(evidence: "\(name) \(before ?? "nil") → \(after ?? "nil")",
                             witness: (name, before, after))
        }
        return .dispatched
    }
}

extension GhostHands {
    /// Press the control named `name` in `appSpec`'s UI — cursor-less, via AX,
    /// no focus steal.
    ///
    /// Honesty contract (nothing here ever hardcodes success):
    /// - throws `.accessibilityNotTrusted` if AX permission is missing,
    /// - throws `.elementNotFound` if no pressable control has that name,
    /// - throws `.ambiguousMatch` if more than one distinct control matches,
    /// - throws `.locatorIndexOutOfRange` if a `--nth` locator is out of range,
    /// - throws `.actionRejected` if the control refuses AXPress,
    /// - otherwise returns an outcome that is honest about whether the effect
    ///   was *verified* (observed change) or merely *dispatched* (AX accepted,
    ///   effect not observable from the element).
    ///
    /// `locator` is the OPT-IN caller disambiguation (--role/--text/--nth). The
    /// default `.none` is byte-for-byte the pre-flag behavior (refuse-on-ambiguous).
    @MainActor
    public static func click(name: String, appSpec: String,
                             locator: LocatorSpec = .none,
                             settle: TimeInterval = 0.15) throws -> ClickOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }

        let target = try Target.resolve(appSpec)

        let element: Element
        let facts: ElementFacts
        switch Finder.resolve(named: name, under: target.element, locator: locator) {
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
        let before = facts.value
        // The structural read-back uses the value-EXCLUDED stable key so a value
        // flip doesn't read as a disappearance.
        let stableIdentity = NameMatch.stableIdentityKey(facts)

        // BEFORE the press: snapshot value-bearing witnesses scoped to the
        // pressed control's enclosing window subtree (so an unrelated window or
        // the menu-bar clock can never become false evidence). The probe pins
        // that window's stable CGWindowID so the AFTER walk re-reads the SAME
        // window by identity — never a positional "window 0" fallback, which on a
        // multi-window app could diff witnesses across the WRONG window and
        // fabricate a change our press never caused. (See EffectProbe.)
        let probe = EffectProbe(pid: target.pid, settle: settle)
        let witnessBeforeState = probe.captureBefore(of: element)

        // OPT-IN observability (GHOSTHANDS_HIGHLIGHT=1): flash a box at the target's
        // on-screen frame just before pressing, so a human SEES where we act. Pure
        // overlay — no cursor move, no focus steal; off by default = zero cost.
        if Highlight.isEnabled, let frame = element.frame() {
            Highlight.flash(frame)
        }

        guard element.press() else {
            throw GhostHandsError.actionRejected(name: name, action: "AXPress")
        }

        // Read the world back off a FRESH application element — never the stale
        // handle we already pressed. A bare "absent" is NOT yet evidence — the
        // project's own AX read flakiness (EAGAIN / cold post-press tree)
        // produces the same miss, so the probe CONFIRMS a disappearance with a
        // settle + second read before treating it as structural "gone".
        let (readback, readbackRoot) =
            probe.readbackSelf(stableIdentity: stableIdentity, named: name,
                               accept: Finder.isActionable)

        // The value to REPORT as `valueAfter` is the control's current value when
        // it is still present; for disabled / gone there is no current value to
        // quote, so it is nil (the evidence string carries the state instead).
        let after: String?
        if case let .present(value) = readback { after = value } else { after = nil }

        // AFTER the press: diff witnesses off the SAME window (settle-twice,
        // keep-only-settled, demote-on-2+ — all inside EffectProbe.diff).
        let witnessDiff = probe.diff(witnessBeforeState, readbackRoot: readbackRoot)

        let verdict = ClickVerdict.decide(selfBefore: before, readback: readback,
                                          witnessDiff: witnessDiff)

        let verified: Bool
        let evidence: String?
        let witnessName: String?
        let witnessBefore: String?
        let witnessAfter: String?
        switch verdict {
        case let .verified(ev, witness):
            verified = true
            evidence = ev
            witnessName = witness?.name
            witnessBefore = witness?.before
            witnessAfter = witness?.after
        case .dispatched:
            verified = false
            evidence = nil
            witnessName = nil
            witnessBefore = nil
            witnessAfter = nil
        }

        return ClickOutcome(app: target.name, name: name, role: role,
                            axAccepted: true, verified: verified, evidence: evidence,
                            valueBefore: before, valueAfter: after,
                            witnessName: witnessName, witnessBefore: witnessBefore,
                            witnessAfter: witnessAfter)
    }
}
