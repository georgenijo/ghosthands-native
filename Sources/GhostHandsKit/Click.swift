import AppKit
import ApplicationServices
import AXorcist
import Foundation

/// The outcome of a click — carries the world-evidence, not a bare boolean.
/// `axAccepted` is the AX layer's own verdict (`press()` succeeded); the
/// before/after values are read back off a FRESH element so the caller can see
/// what actually changed rather than trusting our memory of having acted.
public struct ClickOutcome: Sendable, Equatable {
    public let app: String
    public let name: String
    public let role: String
    public let axAccepted: Bool
    public let valueBefore: String?
    public let valueAfter: String?

    public var valueChanged: Bool { valueBefore != valueAfter }
    /// The honesty floor: the AX layer accepted the action. (A deeper
    /// effect-level assertion — diff the whole tree — is M2.)
    public var landed: Bool { axAccepted }
}

extension GhostHands {
    /// Press the element named `name` in `appSpec`'s UI — cursor-less, via AX,
    /// no focus steal.
    ///
    /// Honesty contract (nothing here ever hardcodes success):
    /// - throws `.accessibilityNotTrusted` if AX permission is missing,
    /// - throws `.elementNotFound` if the name isn't on screen (refuse-on-no-op),
    /// - throws `.actionRejected` if the element refuses AXPress,
    /// - otherwise returns the AX-accepted outcome with the element's value read
    ///   back before/after as evidence.
    @MainActor
    public static func click(name: String, appSpec: String,
                             settle: TimeInterval = 0.15) throws -> ClickOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }

        let target = try Target.resolve(appSpec)
        guard let element = Finder.clickable(named: name, under: target.element) else {
            throw GhostHandsError.elementNotFound(name: name, app: target.name)
        }

        let role = element.role() ?? "AXUnknown"
        let before = axString(element.value())

        guard element.press() else {
            throw GhostHandsError.actionRejected(name: name, action: "AXPress")
        }

        if settle > 0 { Thread.sleep(forTimeInterval: settle) }

        // Re-resolve against a FRESH application element — the read-back must be
        // the world, not a stale handle we already touched.
        let freshRoot = Element(AXUIElementCreateApplication(target.pid))
        let fresh = Finder.clickable(named: name, under: freshRoot) ?? element
        let after = axString(fresh.value())

        return ClickOutcome(app: target.name, name: name, role: role,
                            axAccepted: true, valueBefore: before, valueAfter: after)
    }
}
