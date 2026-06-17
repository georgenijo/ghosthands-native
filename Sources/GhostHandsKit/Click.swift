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

    public var valueChanged: Bool { valueBefore != valueAfter }
    /// The AX layer accepted the dispatch. NOT proof of effect — see `verified`.
    public var landed: Bool { axAccepted }
}

extension GhostHands {
    /// Press the control named `name` in `appSpec`'s UI — cursor-less, via AX,
    /// no focus steal.
    ///
    /// Honesty contract (nothing here ever hardcodes success):
    /// - throws `.accessibilityNotTrusted` if AX permission is missing,
    /// - throws `.elementNotFound` if no pressable control has that name,
    /// - throws `.ambiguousMatch` if more than one distinct control matches,
    /// - throws `.actionRejected` if the control refuses AXPress,
    /// - otherwise returns an outcome that is honest about whether the effect
    ///   was *verified* (observed change) or merely *dispatched* (AX accepted,
    ///   effect not observable from the element).
    @MainActor
    public static func click(name: String, appSpec: String,
                             settle: TimeInterval = 0.15) throws -> ClickOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }

        let target = try Target.resolve(appSpec)

        let element: Element
        let facts: ElementFacts
        switch Finder.resolve(named: name, under: target.element) {
        case let .element(found, foundFacts):
            element = found
            facts = foundFacts
        case let .ambiguous(candidates):
            throw GhostHandsError.ambiguousMatch(name: name, candidates: candidates)
        case .none:
            throw GhostHandsError.elementNotFound(name: name, app: target.name)
        }

        let role = facts.role ?? "AXUnknown"
        let before = facts.value
        let identity = NameMatch.identityKey(facts)

        guard element.press() else {
            throw GhostHandsError.actionRejected(name: name, action: "AXPress")
        }

        // Read the world back off a FRESH application element — never the stale
        // handle we already pressed.
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }  // CLI is one-shot; main thread is free to block
        let freshRoot = Element(AXUIElementCreateApplication(target.pid))

        let after: String?
        let gone: Bool
        if let fresh = Finder.refind(identity: identity, named: name, under: freshRoot) {
            after = axString(fresh.value())
            gone = false
        } else {
            after = nil
            gone = true  // the control changed/relabelled/disappeared — itself evidence
        }

        let valueChanged = before != after
        let verified = valueChanged || gone
        let evidence: String?
        if valueChanged {
            evidence = "value \(before ?? "nil") → \(after ?? "nil")"
        } else if gone {
            evidence = "target no longer present after press"
        } else {
            evidence = nil
        }

        return ClickOutcome(app: target.name, name: name, role: role,
                            axAccepted: true, verified: verified, evidence: evidence,
                            valueBefore: before, valueAfter: after)
    }
}
