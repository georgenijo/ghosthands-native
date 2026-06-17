import AppKit
import ApplicationServices
import AXorcist
import Foundation

/// One node of a snapshot tree: pure facts + its depth + ordered children.
/// Building these from live `Element`s is the only AX-touching step; the
/// rendering below is pure, so the formatter is unit-tested with no app driven.
public struct SnapshotNode: Sendable, Equatable {
    public var facts: ElementFacts
    public var depth: Int
    public var children: [SnapshotNode]

    public init(facts: ElementFacts, depth: Int, children: [SnapshotNode] = []) {
        self.facts = facts
        self.depth = depth
        self.children = children
    }
}

/// Pure rendering of a snapshot forest (the top-level windows). No AX here — the
/// input is a fabricated-or-real node tree, so both formats are hermetically
/// testable. HONEST: it prints exactly what the nodes carry; an empty forest
/// renders an empty string, never a fabricated placeholder.
public enum SnapshotRender {
    /// A human-readable display label for a node — title, else identifier, else
    /// value, else description, else the cleaned role (mirrors AXorcist's
    /// `computedName` precedence). Returns nil only when nothing is nameable.
    public static func displayName(_ f: ElementFacts) -> String? {
        for candidate in [f.title, f.identifier, f.value, f.descriptionText, f.roleDescription] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        if let role = f.role, !role.isEmpty {
            return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        }
        return nil
    }

    /// One indented line per node, e.g. `    AXButton "7"  (disabled)`. The role
    /// is always shown (so static text vs button is visible); the name is
    /// quoted when present; a disabled control is flagged.
    public static func line(_ node: SnapshotNode) -> String {
        let indent = String(repeating: "  ", count: node.depth)
        let role = node.facts.role ?? "AXUnknown"
        var parts = [role]
        if let name = displayName(node.facts), name != role {
            // The role is already shown; avoid repeating it when name == role.
            parts.append(name.debugDescription)
        }
        // Show a value distinct from the name (the running display value).
        if let value = node.facts.value, !value.isEmpty,
           displayName(node.facts) != value {
            parts.append("value=\(value.debugDescription)")
        }
        if node.facts.enabled == false { parts.append("(disabled)") }
        return indent + parts.joined(separator: " ")
    }

    /// The full indented `--ax` tree (depth-first, pre-order).
    public static func ax(_ forest: [SnapshotNode]) -> String {
        var out: [String] = []
        func walk(_ node: SnapshotNode) {
            out.append(line(node))
            for child in node.children { walk(child) }
        }
        for root in forest { walk(root) }
        return out.joined(separator: "\n")
    }

    /// Total node count of a forest (for the honest "N elements" footer / JSON).
    public static func count(_ forest: [SnapshotNode]) -> Int {
        forest.reduce(0) { $0 + 1 + count($1.children) }
    }

    /// A JSON array of per-element dicts (pre-order, depth included). Built by
    /// hand to keep field order stable and avoid a Codable dependency for one
    /// shape. Values are JSON-escaped.
    public static func json(_ forest: [SnapshotNode]) -> String {
        var dicts: [String] = []
        func walk(_ node: SnapshotNode) {
            let f = node.facts
            var fields: [String] = []
            fields.append("\"depth\": \(node.depth)")
            fields.append("\"role\": \(jsonString(f.role))")
            fields.append("\"title\": \(jsonString(f.title))")
            fields.append("\"identifier\": \(jsonString(f.identifier))")
            fields.append("\"value\": \(jsonString(f.value))")
            fields.append("\"roleDescription\": \(jsonString(f.roleDescription))")
            fields.append("\"descriptionText\": \(jsonString(f.descriptionText))")
            fields.append("\"enabled\": \(f.enabled.map(String.init(describing:)) ?? "null")")
            fields.append("\"supportsPress\": \(f.supportsPress)")
            dicts.append("  { " + fields.joined(separator: ", ") + " }")
            for child in node.children { walk(child) }
        }
        for root in forest { walk(root) }
        return "[\n" + dicts.joined(separator: ",\n") + "\n]"
    }

    /// JSON-encode an optional string to a quoted literal or `null`.
    static func jsonString(_ s: String?) -> String {
        guard let s else { return "null" }
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }
}

/// The AX-touching tree walk that builds a `SnapshotNode` forest. Drives the
/// top level from `windows()` and recurses with raw `children(strict: true)` so
/// the dump is a real parent → child tree, not the over-collecting search
/// funnel. Adds its own depth cap and visited-set (AXorcist's `children()` is
/// for SEARCH, not a clean tree).
@MainActor
enum SnapshotWalker {
    static let maxDepth = 60

    /// Walk an app root into a forest of window subtrees.
    static func forest(of appRoot: Element) -> [SnapshotNode] {
        let windows = appRoot.windows() ?? []
        var visited = Set<Element>()
        return windows.map { node(from: $0, depth: 0, visited: &visited) }
    }

    private static func node(from element: Element, depth: Int,
                             visited: inout Set<Element>) -> SnapshotNode {
        let facts = Finder.facts(of: element)
        guard depth < maxDepth, !visited.contains(element) else {
            return SnapshotNode(facts: facts, depth: depth, children: [])
        }
        visited.insert(element)
        // strict:true → real kAXChildren only, no alternative-attribute merge.
        let kids = element.children(strict: true) ?? []
        let childNodes = kids.map { node(from: $0, depth: depth + 1, visited: &visited) }
        return SnapshotNode(facts: facts, depth: depth, children: childNodes)
    }
}

extension GhostHands {
    /// The shape of a snapshot result handed to the CLI.
    public struct SnapshotResult: Sendable {
        public let app: String
        public let forest: [SnapshotNode]
        public var count: Int { SnapshotRender.count(forest) }
    }

    /// Read the app's window AX tree — pure read, no press, no focus steal.
    ///
    /// Honesty contract: dumps exactly what AX reports. If the FIRST read is
    /// empty (a cold/just-bound window hands back a sparse tree a beat before it
    /// fills), it settles once and re-reads — re-reading the real world is not
    /// dishonest. A genuinely empty app stays empty after that single retry.
    @MainActor
    public static func snapshot(appSpec: String,
                                settle: TimeInterval = 0.4) throws -> SnapshotResult {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        var forest = SnapshotWalker.forest(of: target.element)
        if SnapshotRender.count(forest) == 0, settle > 0 {
            Thread.sleep(forTimeInterval: settle)
            let fresh = Element(AXUIElementCreateApplication(target.pid))
            forest = SnapshotWalker.forest(of: fresh)
        }
        return SnapshotResult(app: target.name, forest: forest)
    }
}
