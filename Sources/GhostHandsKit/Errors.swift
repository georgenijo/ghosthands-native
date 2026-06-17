import Foundation

/// Every failure mode of the act tier, each a clean one-liner — never a
/// traceback, never a silent success. These are the honesty boundary: if we
/// can't prove the action happened, we raise instead of reporting "done".
public enum GhostHandsError: Error, CustomStringConvertible, Sendable {
    /// Accessibility (AX) permission not granted to this process.
    case accessibilityNotTrusted
    /// No running application matched the given spec (pid / bundle id / name).
    case appNotFound(String)
    /// The spec matched more than one distinct app — refuse rather than guess.
    case appAmbiguous(spec: String, candidates: [String])
    /// The named element is not on screen — the honest refuse-on-no-op.
    case elementNotFound(name: String, app: String)
    /// The name matched more than one distinct on-screen control — refuse
    /// rather than press an arbitrary (possibly destructive) one.
    case ambiguousMatch(name: String, candidates: [String])
    /// The element was found but rejected the AX action (no-op at the AX layer).
    case actionRejected(name: String, action: String)
    /// Screen Recording permission not granted — `shot` REFUSES rather than
    /// write the black image the OS hands back without the grant.
    case screenRecordingNotTrusted
    /// The app has no on-screen windows to capture (nothing to shoot).
    case noWindows(app: String)
    /// Capture was attempted (with permission) but produced no usable pixels —
    /// e.g. an off-screen/occluded window. Honest REFUSE, no blank PNG written.
    case captureFailed(reason: String)

    public var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "accessibility permission not granted — enable 'ghosthands' "
                + "(or the launching terminal) in System Settings ▸ Privacy & "
                + "Security ▸ Accessibility"
        case let .appNotFound(spec):
            return "no running app matching \(spec.debugDescription)"
        case let .appAmbiguous(spec, candidates):
            return "\(spec.debugDescription) matches \(candidates.count) apps "
                + "(\(candidates.joined(separator: ", "))) — be more specific"
        case let .elementNotFound(name, app):
            return "no element named \(name.debugDescription) on screen in \(app)"
        case let .ambiguousMatch(name, candidates):
            return "\(name.debugDescription) is ambiguous — \(candidates.count) "
                + "controls match (\(candidates.joined(separator: ", "))) — "
                + "use a more specific name"
        case let .actionRejected(name, action):
            return "\(action) rejected by \(name.debugDescription) — element "
                + "found but did not accept the action"
        case .screenRecordingNotTrusted:
            return "Screen Recording not granted — enable 'ghosthands' (or the "
                + "launching terminal) in System Settings ▸ Privacy & Security ▸ "
                + "Screen Recording. The AX tree still works: try ghosthands snapshot"
        case let .noWindows(app):
            return "no on-screen windows to capture in \(app)"
        case let .captureFailed(reason):
            return "screenshot capture failed: \(reason)"
        }
    }
}
