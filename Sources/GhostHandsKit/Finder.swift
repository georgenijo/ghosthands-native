import AXorcist
import Foundation

/// Stringify an AX value (which arrives as `Any?`) for matching and read-back.
///
/// AXorcist's `value()` is a generic `attribute(Attribute<Any>(kAXValue))`, and
/// a generic `Any` fetch of an absent/empty attribute can come back as
/// `Optional<Any>.some(Optional<T>.none)` — a *boxed* nil. The outer optional is
/// non-nil, so a naïve `String(describing:)` renders the literal text `"nil"`
/// and a truly-empty readout (a blank calculator display) masquerades as the
/// constant string "nil": it never appears to change, so the effect-witness
/// stays silent AND `snapshot` prints a fabricated value. We peel any boxed
/// optional with `Mirror` so an empty value is honestly `nil`.
func axString(_ value: Any?) -> String? {
    guard let value else { return nil }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        // `.some(x)` → unwrap and recurse; `.none` (a boxed nil) → genuinely empty.
        guard let inner = mirror.children.first?.value else { return nil }
        return axString(inner)
    }
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return String(describing: value)
}

/// Read a control's AXValue as a String, ROBUSTLY.
///
/// AXorcist's generic `value()` is `attribute(Attribute<Any>(kAXValue))`, whose
/// `Any`-typed convert step returns **nil for some controls whose AXValue is a
/// plain CFString** — notably `AXTextArea` / `AXTextField`. That silent nil is a
/// correctness hole, not just cosmetics: `snapshot`/`find` miss a field's
/// contents, and — worse for the honesty model — `type`/`set-value` read the
/// field back as empty after a set that genuinely landed, so a real, verifiable
/// change is reported as the honest-but-wrong DISPATCHED-UNVERIFIED (a false
/// negative). We fall back to the RAW attribute copy
/// (`AXUIElementCopyAttributeValue`, the exact path that returns the string),
/// so a text control's value is read the same way a screen reader reads it.
/// The fallback only fires when the typed read already yielded nil, so it never
/// changes a control whose `value()` already worked (no M2 regression).
@MainActor
func axValueString(_ element: Element) -> String? {
    if let v = axString(element.value()) { return v }
    if let raw = element.rawAttributeValue(named: AXAttributeNames.kAXValueAttribute) {
        return axString(raw)
    }
    return nil
}

/// Pure, AX-free facts about one element — the unit-testable surface of name
/// resolution. Building these from a live `Element` is the only AX-touching
/// step; the matching/scoring/resolution below is pure, so it is tested with
/// no app driven.
public struct ElementFacts: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    public var value: String?
    public var roleDescription: String?
    public var descriptionText: String?
    public var supportsPress: Bool
    public var enabled: Bool?
    /// The control's full advertised AX action list (e.g. ["AXPress","AXShowMenu"]).
    /// Used by `act` for the pre-check (REFUSE if the requested action is absent)
    /// and by `doubleclick` to prefer AXOpen. May be empty when AX returns nil.
    public var supportedActions: [String]

    public init(role: String? = nil, subrole: String? = nil, title: String? = nil,
                identifier: String? = nil, value: String? = nil,
                roleDescription: String? = nil, descriptionText: String? = nil,
                supportsPress: Bool = false, enabled: Bool? = nil,
                supportedActions: [String] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.value = value
        self.roleDescription = roleDescription
        self.descriptionText = descriptionText
        self.supportsPress = supportsPress
        self.enabled = enabled
        self.supportedActions = supportedActions
    }

    /// True iff the control advertises a named AX action — the honest pre-check
    /// for `act`/`doubleclick` (gate BEFORE dispatch, never throw-and-guess).
    public func supports(_ action: String) -> Bool { supportedActions.contains(action) }
    /// Convenience: advertises AXOpen (the AX double-click equivalent).
    public var supportsOpen: Bool { supportedActions.contains("AXOpen") }
    /// True iff this is a password field — its value is unreadable, so a `type`
    /// into it can never be verified (the secure-field honesty gate).
    public var isSecureTextField: Bool { role == "AXTextField" && subrole == "AXSecureTextField" }
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

    /// Identity of a logical control EXCLUDING its value — for re-finding the
    /// SAME control across a press even when the press flipped its value (a
    /// toggle whose value goes "off" → "on", or a button whose AXValue updates).
    /// Keying the read-back on the value-inclusive `identityKey` would make any
    /// value flip look like the control "disappeared", so the structural
    /// present/disabled/absent check uses this stable key instead.
    public static func stableIdentityKey(_ f: ElementFacts) -> String {
        [f.role, f.title, f.identifier].map { $0 ?? "" }.joined(separator: "\u{1}")
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
    nonisolated static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton",
        "AXPopUpButton", "AXLink", "AXDisclosureTriangle", "AXIncrementor",
        "AXSegmentedControl", "AXTab", "AXTabButton", "AXSlider", "AXStepper",
        "AXSwitch", "AXToggle", "AXColorWell",
    ]

    /// A candidate we may press: advertises AXPress, OR is a known control role.
    /// Excludes static text, images, groups — things that merely *contain* the
    /// query text but aren't the thing to click.
    nonisolated static func isActionable(_ facts: ElementFacts) -> Bool {
        facts.supportsPress || (facts.role.map { controlRoles.contains($0) } ?? false)
    }

    /// Text-entry roles that accept an `AXValue` STRING set — the candidate set
    /// for `type`. These advertise NEITHER AXPress NOR a control role, so they
    /// bypass `isActionable`/`pressableMatches`; `type` resolves over them
    /// separately. A static label / button is NOT a text-entry control.
    nonisolated static let textEntryRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// A candidate `type` may write into. Role-gated (a label that merely shares
    /// the field's title is excluded), so the FIELD is the unique winner — not an
    /// ambiguity false-positive against its own label.
    nonisolated static func isTextEntry(_ facts: ElementFacts) -> Bool {
        facts.role.map { textEntryRoles.contains($0) } ?? false
    }

    /// The `set-value` candidate set: settable value-bearing controls. A superset
    /// of click's `controlRoles` (which already covers checkbox/switch/slider/
    /// stepper/popup) PLUS the text-entry roles (a combo box / text field also
    /// takes set-value). A static label is excluded — only real controls.
    nonisolated static func isSettable(_ facts: ElementFacts) -> Bool {
        isActionable(facts) || isTextEntry(facts)
    }

    /// The `doubleclick` candidate set: rows / cells / files that OPEN on a
    /// double-click. Widened beyond `isActionable` to include AXRow / AXCell and
    /// text-field file rows (NSOpenPanel exposes a file as an AXTextField with an
    /// AXOpen action but no AXPress). A plain static label is still excluded.
    nonisolated static let openableRoles: Set<String> = [
        "AXRow", "AXCell", "AXTextField", "AXOutline", "AXList",
    ]
    nonisolated static func isOpenable(_ facts: ElementFacts) -> Bool {
        isActionable(facts)
            || (facts.role.map { openableRoles.contains($0) } ?? false)
            || facts.supportsOpen
    }

    static func facts(of element: Element) -> ElementFacts {
        let actions = element.supportedActions() ?? []
        return ElementFacts(
            role: element.role(),
            subrole: element.subrole(),
            title: element.title(),
            identifier: element.identifier(),
            value: axValueString(element),
            roleDescription: element.roleDescription(),
            descriptionText: element.descriptionText(),
            supportsPress: actions.contains("AXPress"),
            enabled: element.isEnabled(),
            supportedActions: actions)
    }

    private static func options() -> ElementSearchOptions {
        var o = ElementSearchOptions()
        o.excludeRoles = excludedRoles
        o.enabledOnly = true   // never press a disabled control (it would no-op)
        return o
    }

    /// (element, facts) for every control matching `name` that passes `accept`.
    /// `accept` is the candidate-set gate — `isActionable` for click, `isTextEntry`
    /// for type, `isSettable` for set-value, `isOpenable` for doubleclick — so all
    /// four verbs share one search/refind/readback core, differing only in which
    /// roles count as a candidate.
    static func candidateMatches(named name: String, under root: Element,
                                 accept: (ElementFacts) -> Bool) -> [(Element, ElementFacts)] {
        root.searchElements(matching: name, options: options())
            .map { ($0, facts(of: $0)) }
            .filter { accept($0.1) }
    }

    /// (element, facts) for every actionable control matching `name`.
    static func pressableMatches(named name: String, under root: Element) -> [(Element, ElementFacts)] {
        candidateMatches(named: name, under: root, accept: isActionable)
    }

    enum Resolved {
        case element(Element, ElementFacts)
        case ambiguous([String])
        case none
    }

    /// Resolve over an arbitrary candidate gate (click uses the `isActionable`
    /// default; type/set-value/doubleclick pass their widened gate). Ambiguity
    /// (>1 distinct control) is refused exactly as in the click path.
    static func resolve(named name: String, under root: Element,
                        accept: (ElementFacts) -> Bool = isActionable) -> Resolved {
        let pairs = candidateMatches(named: name, under: root, accept: accept)
        switch NameMatch.resolve(pairs.map { $0.1 }, query: name) {
        case let .unique(i): return .element(pairs[i].0, pairs[i].1)
        case let .ambiguous(labels): return .ambiguous(labels)
        case .none: return .none
        }
    }

    /// Re-find the SAME logical control (by identity) on a fresh snapshot, so
    /// the read-back reads the world, not the stale handle we already pressed.
    static func refind(identity key: String, named name: String, under root: Element,
                       accept: (ElementFacts) -> Bool = isActionable) -> Element? {
        for (element, facts) in candidateMatches(named: name, under: root, accept: accept)
        where NameMatch.identityKey(facts) == key {
            return element
        }
        return nil
    }

    /// The pressable-matches search options, but WITHOUT the `enabledOnly` gate.
    /// Used only for the post-press read-back: a control that DISABLED ITSELF as
    /// a result of the press is dropped by `enabledOnly` and would masquerade as
    /// "no longer present" (a false structural-gone). Searching enabled+disabled
    /// lets us tell "now disabled" (a real observed state change, honest
    /// evidence) apart from "genuinely absent".
    private static func readbackOptions() -> ElementSearchOptions {
        var o = ElementSearchOptions()
        o.excludeRoles = excludedRoles
        o.enabledOnly = false
        return o
    }

    /// Outcome of re-reading the pressed control's identity off a fresh tree.
    enum Readback: Equatable {
        /// Still present and pressable; carries its current facts (for value /
        /// enabled read-back).
        case present(ElementFacts)
        /// Found by identity but now reports `enabled == false` — a real,
        /// observed state change caused by the press.
        case disabled(ElementFacts)
        /// Not found at all on this read, even ignoring the enabled gate.
        case absent
    }

    /// Re-read the pressed control by STABLE identity (value-excluded) off
    /// `root`, distinguishing present / now-disabled / absent. Searches enabled
    /// AND disabled so a self-disable is reported as `disabled`, never as a
    /// false `absent`. Keyed without value so a legitimate value flip does not
    /// read as a disappearance.
    static func readback(stableIdentity key: String, named name: String, under root: Element,
                         accept: (ElementFacts) -> Bool = isActionable) -> Readback {
        var bestDisabled: ElementFacts?
        for element in root.searchElements(matching: name, options: readbackOptions()) {
            let f = facts(of: element)
            guard accept(f), NameMatch.stableIdentityKey(f) == key else { continue }
            if f.enabled == false {
                bestDisabled = f          // remember, but keep looking for an enabled twin
            } else {
                return .present(f)        // an enabled, matching candidate wins
            }
        }
        if let bestDisabled { return .disabled(bestDisabled) }
        return .absent
    }

    // MARK: - Effect witnesses

    /// Roles whose `AXValue` carries a displayed RESULT we can witness — a
    /// calculator's running total, a text field's contents, a slider's reading.
    /// Buttons/structural roles are deliberately EXCLUDED: a button is the actor
    /// we pressed, never the evidence.
    static let witnessRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXValueIndicator",
        // AXScrollArea carries the displayed value on some modern views (the
        // Calculator display exposes it as the scroll area's AXIdentifier).
        "AXScrollArea",
    ]

    /// Walk UP from a control to its enclosing `AXWindow`, so witnesses are
    /// scoped to the SAME window subtree (kills a menu-bar clock / other
    /// windows / Notification Center as false witnesses). Returns nil if no
    /// window ancestor is found within a small hop budget.
    static func enclosingWindow(of element: Element) -> Element? {
        var current: Element? = element
        var hops = 0
        while let node = current, hops < 64 {
            if node.role() == "AXWindow" { return node }
            current = node.parent()
            hops += 1
        }
        return nil
    }

    /// Collect value-bearing witnesses within `window`'s subtree, keyed on
    /// identity that EXCLUDES value (the very thing that changes). The key is
    /// role + title + identifier + frame + a stable pre-order path, so the SAME
    /// display element matches before/after even as its value flips, while two
    /// distinct unlabelled/un-laid-out siblings (nil frame, no title/id) do NOT
    /// collide onto one key. Bounded by depth + a visited-set. Deterministic
    /// across two reads as long as the tree shape is stable (which is exactly
    /// the case where pairing is meaningful — if the shape moved, the path
    /// differs, the witness is un-pairable, and `diff` correctly ignores it).
    static func witnesses(in window: Element) -> [WitnessMatch.Witness] {
        var visited = Set<Element>()
        var out: [WitnessMatch.Witness] = []
        collectWitnesses(window, depth: 0, path: "", visited: &visited, into: &out)
        return out
    }

    private static func collectWitnesses(_ element: Element, depth: Int, path: String,
                                         visited: inout Set<Element>,
                                         into out: inout [WitnessMatch.Witness]) {
        guard depth < 60, !visited.contains(element) else { return }
        visited.insert(element)

        let role = element.role()
        if let role, witnessRoles.contains(role) {
            // Collect the witness even when its value is currently nil/empty.
            // The single most common effect is an EMPTY readout GAINING a value
            // (a blank calculator display → "7", an empty field → typed text).
            // If we only collected non-empty values, that element would be
            // absent from the BEFORE set and present in AFTER, so `diff` would
            // see it as "appeared" and ignore it — silently under-claiming a
            // real, observable change. Normalising "" ≡ nil, a blank-before /
            // value-after element is one stably-keyed witness whose value flips
            // nil → "789", which `diff` reports as a genuine change. The
            // uniqueness + single-change + window-scope guards still prevent a
            // false positive (two readouts moving → ambiguous → demote).
            let raw = axValueString(element)
            let value = (raw?.isEmpty == true) ? nil : raw
            let title = element.title()
            let id = element.identifier()
            // The observed readout is the element's AXValue. For a true value
            // control (static text / field / value indicator) that is the ONLY
            // honest readout — its AXIdentifier/AXDescription are developer
            // metadata with no contract to track the displayed value, so reading
            // them as "the value" would invite false evidence. The identifier/
            // description fallback is therefore scoped to AXScrollArea ALONE —
            // the one carrier role where a real displayed value is known to ride
            // on the identifier (the modern Calculator display reads
            // `StandardInputView;value:5`). Even there, the stability fence in
            // `click` requires the readout to settle before it is quoted.
            let readout: String?
            if role == "AXScrollArea" {
                readout = WitnessMatch.readout(value: value, identifier: id,
                                               description: element.descriptionText())
            } else {
                readout = value
            }
            let frame = element.frame()
            let frameKey = frame.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? ""
            // Identity is STRUCTURAL ONLY — it excludes value, identifier AND
            // description, because any of those three may be the readout that
            // changes (keying on them would read a value flip as a
            // disappearance, the exact bug that silenced Calculator's display).
            // role + title + frame + `path` (pre-order tree position) keeps two
            // otherwise-identical, frame-less siblings on DISTINCT keys, so they
            // can never be (mis)paired by `diff`.
            let key = [role, title ?? "", frameKey, path].joined(separator: "\u{1}")
            let name = title ?? (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
            out.append(WitnessMatch.Witness(key: key, name: name, value: readout))
        }
        let children = element.children(strict: true) ?? []
        for (i, child) in children.enumerated() {
            collectWitnesses(child, depth: depth + 1, path: "\(path).\(i)",
                             visited: &visited, into: &out)
        }
    }
}
