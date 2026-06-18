import ApplicationServices
import AXorcist
import Foundation

/// The outcome of the `focus` verb — honest about whether the control was
/// OBSERVED to hold keyboard focus (AXFocused read back `true` → VERIFIED) or
/// merely DISPATCHED (AX accepted the `AXFocused = true` set, but the read-back
/// was not `true`). Mirrors `ValueOutcome`/`ActOutcome`: `axAccepted` is the
/// dispatch; `verified` is the observed state, computed by `FocusVerdict.decide`
/// from the AXFocused read-back, NEVER from the setValue boolean.
public struct FocusOutcome: Sendable, Equatable {
    public let app: String
    public let name: String
    public let role: String
    public let axAccepted: Bool
    public let verified: Bool
    /// The AXFocused attribute as re-read off a fresh tree: `true` = observed
    /// focused, `false` = observed not focused, `nil` = AXFocused unreadable on
    /// this control (focus unwitnessable).
    public let focusedAfter: Bool?
    public let evidence: String?

    public init(app: String, name: String, role: String, axAccepted: Bool,
                verified: Bool, focusedAfter: Bool?, evidence: String?) {
        self.app = app
        self.name = name
        self.role = role
        self.axAccepted = axAccepted
        self.verified = verified
        self.focusedAfter = focusedAfter
        self.evidence = evidence
    }
}

extension GhostHands {
    /// `focus "<name>" <app>` — give a named control KEYBOARD FOCUS via AX, then
    /// read AXFocused back to verify. Cursor-less, no synthetic clicks.
    ///
    /// Honesty contract (same name resolution as click/type/set-value):
    /// - refuses (throws) when the control is not found / ambiguous,
    /// - sets `AXFocused = true` (a Bool, which bridges through AXorcist's
    ///   `setValue(forAttribute:)`); a `setValue==false` (AX rejected outright)
    ///   REFUSES,
    /// - VERIFIED only when AXFocused reads back `true` off a FRESH tree — never
    ///   off the setValue boolean,
    /// - DISPATCHED-UNVERIFIED (returned, not thrown) when AX accepted the set but
    ///   AXFocused does NOT read back true (false, or unreadable/unsettable nil):
    ///   the focus could not be observed, reported plainly, never faked.
    @MainActor
    public static func focus(name: String, appSpec: String,
                             settle: TimeInterval = 0.15) throws -> FocusOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        let element: Element
        let facts: ElementFacts
        // Same candidate gate as set-value/act: any settable, value-bearing or
        // actionable control (text fields, buttons, checkboxes, …) can be focused.
        switch Finder.resolve(named: name, under: target.element, accept: Finder.isSettable) {
        case let .element(found, foundFacts):
            element = found
            facts = foundFacts
        case let .ambiguous(candidates):
            throw GhostHandsError.ambiguousMatch(name: name, candidates: candidates)
        case .none:
            throw GhostHandsError.elementNotFound(name: name, app: target.name)
        }

        let role = facts.role ?? "AXUnknown"
        let (accepted, focusedAfter) = setFocused(element: element, facts: facts,
                                                   pid: target.pid, settle: settle)

        // DISPATCH gate: setValue==false means AX rejected the focus set outright
        // → REFUSE (no fabricated success), exactly like the value path.
        guard accepted else {
            throw GhostHandsError.actionRejected(name: name, action: "AXFocused set")
        }

        switch FocusVerdict.decide(focusedAfter: focusedAfter) {
        case let .verified(evidence):
            return FocusOutcome(app: target.name, name: name, role: role,
                                axAccepted: true, verified: true,
                                focusedAfter: focusedAfter, evidence: evidence)
        case .dispatched:
            return FocusOutcome(app: target.name, name: name, role: role,
                                axAccepted: true, verified: false,
                                focusedAfter: focusedAfter, evidence: nil)
        }
    }

    /// Set `AXFocused = true` on `element`, settle, then RE-READ AXFocused off a
    /// FRESH tree (by stable identity) and return `(accepted, focusedAfter)`:
    /// - `accepted`     : the setValue boolean (a DISPATCH, not a success),
    /// - `focusedAfter` : the AXFocused attribute re-read (`true`/`false`/`nil`),
    ///   the SOLE evidence the verdict consults.
    ///
    /// Shared by the `focus` verb AND `type`'s best-effort auto-focus, so both go
    /// through the same dispatch-then-read-back machinery.
    @MainActor
    static func setFocused(element: Element, facts: ElementFacts, pid: pid_t,
                           settle: TimeInterval) -> (accepted: Bool, focusedAfter: Bool?) {
        // AXFocused is a Bool attribute; `true` bridges through setValue.
        let accepted = element.setValue(true, forAttribute: AXAttributeNames.kAXFocusedAttribute)
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }

        // Re-read AXFocused off a FRESH application root (never the stale handle).
        // Re-find the SAME logical control by identity, then read its AXFocused;
        // if the control can't be re-found, fall back to the original handle's
        // read (still a real read, just not off a fresh tree). `refind` keys on
        // the value-inclusive `identityKey` — a focus flip does not change the
        // control's value, so the key is stable across the set.
        let key = NameMatch.identityKey(facts)
        let freshRoot = Element(AXUIElementCreateApplication(pid))
        let target = Finder.refind(identity: key, named: facts.title ?? facts.identifier ?? "",
                                   under: freshRoot, accept: Finder.isSettable) ?? element
        return (accepted, target.isFocused())
    }
}
