import AppKit
import ApplicationServices
import AXorcist

/// A resolved target application and its AX application element.
///
/// Resolution by pid / bundle id / (whole or partial) localized name is ported
/// from Peekaboo's `NSWorkspace.runningApplications` match (MIT — see
/// ATTRIBUTION.md). A running-but-uninstalled app (dev build / unsigned `.app`)
/// resolves by its visible name, not just its pid.
@MainActor
public struct Target {
    public let app: NSRunningApplication
    public let pid: pid_t
    /// The AX application element — root of this app's accessibility tree.
    public let element: Element

    public var name: String {
        app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
    }

    public init(app: NSRunningApplication) {
        self.app = app
        self.pid = app.processIdentifier
        self.element = Element(AXUIElementCreateApplication(app.processIdentifier))
    }

    public static func resolve(_ spec: String) throws -> Target {
        let apps = NSWorkspace.shared.runningApplications

        if let wantedPid = pid_t(spec),
           let hit = apps.first(where: { $0.processIdentifier == wantedPid }) {
            return Target(app: hit)
        }

        let lowered = spec.lowercased()
        let exact = apps.first { app in
            app.bundleIdentifier?.lowercased() == lowered
                || app.localizedName?.lowercased() == lowered
        }
        let partial = apps.first { app in
            (app.bundleIdentifier?.lowercased().contains(lowered) ?? false)
                || (app.localizedName?.lowercased().contains(lowered) ?? false)
        }
        guard let hit = exact ?? partial else {
            throw GhostHandsError.appNotFound(spec)
        }
        return Target(app: hit)
    }
}
