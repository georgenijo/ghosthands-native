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
/// step; the matching/scoring/resolution below is pure, so it is tested with
/// no app driven.
public struct ElementFacts: Sendable, Equatable {
    public var role: String?
    public var title: String?
    public var identifier: String?
    public var value: String?
    public var roleDescription: String?
    public var descriptionText: String?
    public var supportsPress: Bool
    public var enabled: Bool?

    public init(role: String? = nil, title: String? = nil, identifier: String? = nil,
                value: String? = nil, roleDescription: String? = nil,
                descriptionText: String? = nil, supportsPress: Bool = false,
                enabled: Bool? = nil) {
        self.role = role
        self.title = title
        self.identifier = identifier
        self.value = value
        self.roleDescription = roleDescription
        self.descriptionText = descriptionText
        self.supportsPress = supportsPress
        self.enabled = enabled
    }
}

/// Pure name-matching + resolution. Prefers exact whole-string matches, refuses
/// when more than one DISTINCT control matches (ambiguity is a wrong-target
/// risk, so it is surfaced, never silently resolved).
public enum NameMatch {
    public static func matches(_ f: ElementFacts, query: String) -> Bool {
        let q = query.lowercased()
        for text in [f.title, f.identifier, f.value, f.roleDescription, f.descriptionText] {
            if let text, text.lowercased().contains(q) { return true }
        }
        return false
    }

    /// Higher = better, used only to pick the best member WITHIN one logical
    /// control (e.g. an exact title beats a partial). Cross-control ties are
    /// not broken by score — they are reported as ambiguous.
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

    /// A whole-string (not substring) match on a primary field.
    public static func isExact(_ f: ElementFacts, query: String) -> Bool {
        let q = query.lowercased()
        return f.title?.lowercased() == q
            || f.identifier?.lowercased() == q
            || f.value?.lowercased() == q
    }

    /// Identity of a logical control — collapses the same element rendered in
    /// two AXWindow subtrees (a known duplicate-render quirk) into one.
    public static func identityKey(_ f: ElementFacts) -> String {
        [f.role, f.title, f.identifier, f.value].map { $0 ?? "" }.joined(separator: "\u{1}")
    }

    public enum Resolution: Equatable {
        case unique(Int)            // index into the candidates passed in
        case ambiguous([String])    // human labels of the distinct candidates
        case none
    }

    /// Resolve candidates (already filtered to pressable + name-matched) to a
    /// single index, ambiguity, or none. Exact matches win over substring; the
    /// surviving set is grouped by identity, and >1 distinct group → ambiguous.
    public static func resolve(_ candidates: [ElementFacts], query: String) -> Resolution {
        guard !candidates.isEmpty else { return .none }

        let exact = candidates.indices.filter { isExact(candidates[$0], query: query) }
        let pool = exact.isEmpty ? Array(candidates.indices) : exact

        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for i in pool {
            let key = identityKey(candidates[i])
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }

        if order.count == 1 {
            let members = groups[order[0]]!
            let best = members.max {
                score(candidates[$0], query: query) < score(candidates[$1], query: query)
            }!
            return .unique(best)
        }

        let labels = order.map { key -> String in
            let f = candidates[groups[key]!.first!]
            return "\(f.title ?? f.identifier ?? f.value ?? "?") [\(f.role ?? "?")]"
        }
        return .ambiguous(labels)
    }
}

/// Bridges live AXorcist `Element`s into facts and applies `NameMatch`. Only
/// pressable, enabled, on-screen controls are candidates — a static label or a
/// disabled/hidden control can never be the thing we press.
@MainActor
enum Finder {
    /// Menus are a separate concern (frontmost-only, AXPick; see the
    /// no-foreground contract) — excluding them stops `click "7"` from matching
    /// a hidden "Decimal Places ▸ 7" menu item instead of the keypad button.
    static let excludedRoles: Set<String> = [
        "AXMenuItem", "AXMenuBarItem", "AXMenu", "AXMenuBar",
    ]

    /// Interactive control roles. `supportedActions()` (a generic attribute
    /// fetch) can return nil even for a genuinely pressable AXButton, so role
    /// is the reliable gate; AXPress support is a bonus, not a requirement.
    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton",
        "AXPopUpButton", "AXLink", "AXDisclosureTriangle", "AXIncrementor",
        "AXSegmentedControl", "AXTab", "AXTabButton", "AXSlider", "AXStepper",
        "AXSwitch", "AXToggle", "AXColorWell",
    ]

    /// A candidate we may press: advertises AXPress, OR is a known control role.
    /// Excludes static text, images, groups — things that merely *contain* the
    /// query text but aren't the thing to click.
    static func isActionable(_ facts: ElementFacts) -> Bool {
        facts.supportsPress || (facts.role.map { controlRoles.contains($0) } ?? false)
    }

    static func facts(of element: Element) -> ElementFacts {
        ElementFacts(
            role: element.role(),
            title: element.title(),
            identifier: element.identifier(),
            value: axString(element.value()),
            roleDescription: element.roleDescription(),
            descriptionText: element.descriptionText(),
            supportsPress: element.supportedActions()?.contains("AXPress") ?? false,
            enabled: element.isEnabled())
    }

    private static func options() -> ElementSearchOptions {
        var o = ElementSearchOptions()
        o.excludeRoles = excludedRoles
        o.enabledOnly = true   // never press a disabled control (it would no-op)
        return o
    }

    /// (element, facts) for every actionable control matching `name`.
    static func pressableMatches(named name: String, under root: Element) -> [(Element, ElementFacts)] {
        root.searchElements(matching: name, options: options())
            .map { ($0, facts(of: $0)) }
            .filter { isActionable($0.1) }
    }

    enum Resolved {
        case element(Element, ElementFacts)
        case ambiguous([String])
        case none
    }

    static func resolve(named name: String, under root: Element) -> Resolved {
        let pairs = pressableMatches(named: name, under: root)
        switch NameMatch.resolve(pairs.map { $0.1 }, query: name) {
        case let .unique(i): return .element(pairs[i].0, pairs[i].1)
        case let .ambiguous(labels): return .ambiguous(labels)
        case .none: return .none
        }
    }

    /// Re-find the SAME logical control (by identity) on a fresh snapshot, so
    /// the read-back reads the world, not the stale handle we already pressed.
    static func refind(identity key: String, named name: String, under root: Element) -> Element? {
        for (element, facts) in pressableMatches(named: name, under: root)
        where NameMatch.identityKey(facts) == key {
            return element
        }
        return nil
    }
}
