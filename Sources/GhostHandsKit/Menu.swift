import ApplicationServices
import AXorcist
import Foundation

// `menu "File > Open Recent > ~/path" <app>` — drive an app's REGULAR menu bar
// (File/Edit/View/…), the surface the capability matrix had as DEFERRED. The
// deferral was about MenuBarExtra / Control Center (status items whose AXPress is a
// no-op); a normal app menu IS drivable: each AXMenuBarItem / AXMenuItem advertises
// AXPress, and pressing a submenu parent opens its AXMenu. We resolve the path
// segment by segment, AXPress each, and descend.
//
// HONESTY: a menu action's EFFECT (open a folder, run a command) is downstream and
// app-specific — there is no in-AX observable on the menu itself. So the verdict is
// **dispatched-unverified**, NEVER a fabricated success (mirrors `key` / `act raise`).
// What we DO prove is that every segment resolved to exactly one item and AXPress
// was accepted; a segment that matches nothing or >1 item REFUSES (and we close any
// menu we opened, so a refuse never leaves the app's menu hanging).

// MARK: - Pure: path parsing

public enum MenuPath {
    /// Split a `"File > Open Recent > ~/x"` path into trimmed, non-empty segments.
    /// `>` is the separator; segment text (e.g. a recent-file path) never contains
    /// it. An all-empty/blank path yields `[]` (the caller REFUSES on empty).
    public static func parse(_ s: String) -> [String] {
        s.split(separator: ">", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Pure: one-level matching

public enum MenuMatch {
    /// The outcome of matching a query against the titles at one menu level.
    public enum Choice: Equatable {
        case one(Int)
        case none
        case ambiguous([Int])
    }

    /// Choose the menu item a query names. EXACT (case-insensitive, trimmed) wins
    /// over substring, so `"Open"` doesn't collide with `"Open Recent"` when an
    /// exact `"Open…"`-style item exists; absent an exact hit we fall to substring,
    /// and >1 substring hit is AMBIGUOUS (refuse, never guess). The ellipsis `…`
    /// that menus append is handled naturally by substring (`"Open Folder"` matches
    /// `"Open Folder…"`).
    public static func choose(_ titles: [String], query: String) -> Choice {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let norm = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let exact = norm.indices.filter { norm[$0] == q }
        if exact.count == 1 { return .one(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let subs = norm.indices.filter { !norm[$0].isEmpty && norm[$0].contains(q) }
        if subs.count == 1 { return .one(subs[0]) }
        if subs.count > 1 { return .ambiguous(subs) }
        return .none
    }
}

// MARK: - Outcome

public struct MenuOutcome: Sendable, Equatable {
    public let app: String
    /// The resolved path actually pressed, item by item.
    public let path: [String]
    public let axAccepted: Bool
    /// Always false today: a menu action has no in-AX observable to verify against.
    public let verified: Bool
    public let evidence: String

    public init(app: String, path: [String], axAccepted: Bool,
                verified: Bool, evidence: String) {
        self.app = app
        self.path = path
        self.axAccepted = axAccepted
        self.verified = verified
        self.evidence = evidence
    }
}

// MARK: - Impure: the AX walk

extension GhostHands {
    /// `menu "<A > B > C>" <app>` — open menu A, descend to B, invoke C, all via
    /// AXPress through the Accessibility tree (no cursor, no focus steal). Refuses on
    /// an unresolved app / no menu bar / a segment that matches none or >1 item / a
    /// non-final segment with no submenu / an AX-rejected press — closing any opened
    /// menu on the way out.
    @MainActor
    public static func menu(path rawPath: String, appSpec: String,
                            settle: TimeInterval = 0.15) throws -> MenuOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let segments = MenuPath.parse(rawPath)
        guard !segments.isEmpty else {
            throw GhostHandsError.menuItemNotFound(segment: "", app: appSpec, available: [])
        }
        let target = try Target.resolve(appSpec)
        guard let menuBar = target.element.mainMenu() else {
            throw GhostHandsError.menuBarUnavailable(app: target.name)
        }

        // The element whose menu we opened first — AXCancel it to clean up on refuse.
        var openedTop: Element?
        func closeOpened() { if let t = openedTop { _ = try? t.performAction("AXCancel") } }

        var levelItems: [Element] = menuBar.children(strict: true) ?? []
        for (i, segment) in segments.enumerated() {
            let titles = levelItems.map { $0.title() ?? "" }
            switch MenuMatch.choose(titles, query: segment) {
            case .none:
                closeOpened()
                throw GhostHandsError.menuItemNotFound(
                    segment: segment, app: target.name,
                    available: titles.filter { !$0.isEmpty })
            case let .ambiguous(idxs):
                closeOpened()
                throw GhostHandsError.ambiguousMatch(
                    name: segment, candidates: idxs.map { titles[$0] })
            case let .one(idx):
                let item = levelItems[idx]
                do { _ = try item.performAction("AXPress") }
                catch {
                    closeOpened()
                    throw GhostHandsError.actionRejected(name: segment, action: "AXPress")
                }
                if i == 0 { openedTop = item }
                // Let the (sub)menu populate before reading the next level.
                if settle > 0 { Thread.sleep(forTimeInterval: settle) }
                if i < segments.count - 1 {
                    guard let submenu = item.children(strict: true)?
                            .first(where: { $0.role() == "AXMenu" }),
                          let subItems = submenu.children(strict: true), !subItems.isEmpty
                    else {
                        closeOpened()
                        throw GhostHandsError.notASubmenu(segment: segment, app: target.name)
                    }
                    levelItems = subItems
                }
            }
        }

        let trail = segments.joined(separator: " > ")
        return MenuOutcome(
            app: target.name, path: segments, axAccepted: true, verified: false,
            evidence: "AXPress accepted at each step (\(trail)); a menu action has no "
                + "in-AX observable — effect unverified")
    }
}
