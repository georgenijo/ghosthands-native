import AXorcist
import Foundation

/// Stringify an AX value (which arrives as `Any?`) for matching and read-back.
func axString(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return String(describing: value)
}

/// Pure, AX-free facts about one element — the unit-testable surface of name
/// resolution. Building these from a live `Element` is the only AX-touching
/// step; the matching/scoring below is pure, so ranking is tested with no app.
public struct ElementFacts: Sendable, Equatable {
    public var title: String?
    public var identifier: String?
    public var value: String?
    public var roleDescription: String?
    public var descriptionText: String?
    public var supportsPress: Bool
    public var enabled: Bool?

    public init(title: String? = nil, identifier: String? = nil, value: String? = nil,
                roleDescription: String? = nil, descriptionText: String? = nil,
                supportsPress: Bool = false, enabled: Bool? = nil) {
        self.title = title
        self.identifier = identifier
        self.value = value
        self.roleDescription = roleDescription
        self.descriptionText = descriptionText
        self.supportsPress = supportsPress
        self.enabled = enabled
    }
}

/// Pure name-matching — same contains-semantics AXorcist's tree search uses,
/// plus a ranking that prefers exact title/identifier, then pressable+enabled.
public enum NameMatch {
    public static func matches(_ f: ElementFacts, query: String) -> Bool {
        let q = query.lowercased()
        for text in [f.title, f.identifier, f.value, f.roleDescription, f.descriptionText] {
            if let text, text.lowercased().contains(q) { return true }
        }
        return false
    }

    /// Higher = better. Exact whole-string title/identifier dominate; pressable
    /// and enabled break ties; any genuine substring match outranks none.
    public static func score(_ f: ElementFacts, query: String) -> Int {
        let q = query.lowercased()
        var s = 0
        if f.title?.lowercased() == q { s += 400 }
        if f.identifier?.lowercased() == q { s += 400 }
        if f.value?.lowercased() == q { s += 200 }
        if f.descriptionText?.lowercased() == q { s += 150 }
        if f.supportsPress { s += 100 }
        if f.enabled == true { s += 50 }
        if matches(f, query: query) { s += 10 }
        return s
    }
}

/// Bridges live AXorcist `Element`s into facts, then ranks with `NameMatch`.
@MainActor
enum Finder {
    static func facts(of element: Element) -> ElementFacts {
        ElementFacts(
            title: element.title(),
            identifier: element.identifier(),
            value: axString(element.value()),
            roleDescription: element.roleDescription(),
            descriptionText: element.descriptionText(),
            supportsPress: element.supportedActions()?.contains("AXPress") ?? false,
            enabled: element.isEnabled())
    }

    /// Roles that are not in-window controls — menus are a separate concern
    /// (frontmost-only, AXPick; see the no-foreground contract). Excluding them
    /// stops `click "7"` from matching a hidden "Decimal Places ▸ 7" menu item
    /// instead of the keypad button.
    static let excludedRoles: Set<String> = [
        "AXMenuItem", "AXMenuBarItem", "AXMenu", "AXMenuBar",
    ]

    /// Best clickable element matching `name` anywhere under `root`, or nil
    /// (the honest refuse — nothing on screen by that name).
    static func clickable(named name: String, under root: Element) -> Element? {
        var options = ElementSearchOptions()
        options.excludeRoles = excludedRoles
        let candidates = root.searchElements(matching: name, options: options)
        guard !candidates.isEmpty else { return nil }
        return candidates.max {
            NameMatch.score(facts(of: $0), query: name)
                < NameMatch.score(facts(of: $1), query: name)
        }
    }
}
