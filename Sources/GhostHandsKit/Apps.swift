import AppKit
import Foundation

// `apps` — the app-level EYE: list the running GUI apps (the ones with a Dock
// presence / windows), so a brain can answer "what's open?" before deciding to
// `click "<App>" Dock` to open one, or to drive one that's already running. Pure
// read — no AX tree walk, no focus steal. Faceless background daemons / XPC
// services are excluded (activationPolicy != .regular) so the list matches what a
// human sees in the Dock and Cmd-Tab, not the process table.

public struct AppInfo: Sendable, Equatable {
    public let name: String
    public let bundleID: String?
    public let pid: pid_t
    /// True for the single frontmost (active) app.
    public let active: Bool

    public init(name: String, bundleID: String?, pid: pid_t, active: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.active = active
    }

    /// One honest human line: name, bundle id (when known), pid, and a `[frontmost]`
    /// marker for the active app. Pure — unit-testable without a live workspace.
    public var line: String {
        let bundle = bundleID.map { " (\($0))" } ?? ""
        let front = active ? " [frontmost]" : ""
        return "\(name)\(bundle)  pid=\(pid)\(front)"
    }
}

extension GhostHands {
    /// List running regular (GUI) apps, sorted by name. A pure read of
    /// `NSWorkspace.runningApplications`; nothing is actuated.
    @MainActor
    public static func apps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map {
                AppInfo(name: $0.localizedName ?? ($0.bundleIdentifier ?? "pid \($0.processIdentifier)"),
                        bundleID: $0.bundleIdentifier,
                        pid: $0.processIdentifier,
                        active: $0.isActive)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
