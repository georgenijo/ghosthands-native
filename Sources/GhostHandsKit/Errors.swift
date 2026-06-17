import Foundation

/// Every failure mode of the act tier, each a clean one-liner — never a
/// traceback, never a silent success. These are the honesty boundary: if we
/// can't prove the action happened, we raise instead of reporting "done".
public enum GhostHandsError: Error, CustomStringConvertible, Sendable {
    /// Accessibility (AX) permission not granted to this process.
    case accessibilityNotTrusted
    /// No running application matched the given spec (pid / bundle id / name).
    case appNotFound(String)
    /// The named element is not on screen — the honest refuse-on-no-op.
    case elementNotFound(name: String, app: String)
    /// The element was found but rejected the AX action (no-op at the AX layer).
    case actionRejected(name: String, action: String)

    public var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "accessibility permission not granted — enable 'ghosthands' "
                + "(or the launching terminal) in System Settings ▸ Privacy & "
                + "Security ▸ Accessibility"
        case let .appNotFound(spec):
            return "no running app matching \(spec.debugDescription)"
        case let .elementNotFound(name, app):
            return "no element named \(name.debugDescription) on screen in \(app)"
        case let .actionRejected(name, action):
            return "\(action) rejected by \(name.debugDescription) — element "
                + "found but did not accept the action"
        }
    }
}
