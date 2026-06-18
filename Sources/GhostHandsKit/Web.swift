import AppKit
import ApplicationServices
import AXorcist
import Foundation

// GhostHands WEB read tier — eyes for browser surfaces, AX only, no model.
//
// A browser window's AX tree carries BOTH the browser chrome (an AXToolbar with
// the address/search AXTextField, an AXTabGroup of AXRadioButton/AXTab tabs,
// bookmarks, window furniture) AND the page itself, which lives under a node of
// role `AXWebArea`. The page's real controls and text — AXLink, AXButton,
// AXTextField, AXHeading, AXStaticText — are the AXWebArea's descendants.
//
// `web read`  emits a WEB-SCOPED DIGEST: the page's interactive controls +
//             meaningful text, with all chrome STRIPPED (anything not under an
//             AXWebArea is dropped by construction — we render only the
//             AXWebArea subtree).
// `web tabs`  lists the open tabs (title + which is selected) from the
//             AXTabGroup. HONEST: if no tab group is exposed, it REFUSES rather
//             than guessing.
//
// Honesty contract (same as the rest of the kit): a read reports only what is
// actually on the AX tree. We never fabricate page content, and an empty page /
// a missing web area / un-exposed tabs is reported as such, never papered over.
//
// PURITY: the AX-touching step is a single walk that produces a pure
// `[WebFacts]` tree (a `WebNode` forest of `ElementFacts`). Everything below —
// finding the AXWebArea roots, the chrome filter, the digest keep/drop rule, the
// tab extraction — is a PURE function over that fabricated-or-real tree, so it is
// hermetically unit-tested with no live browser driven.

// MARK: - Pure node model

/// One node of a raw browser AX subtree: pure facts + ordered children. Mirrors
/// `SnapshotNode` but without a baked-in depth — depth is assigned by the pure
/// digest builder relative to the AXWebArea root, so the page reads as its own
/// tree (the chrome above it is not indented into the page's depth).
public struct WebNode: Sendable, Equatable {
    public var facts: ElementFacts
    public var children: [WebNode]

    public init(facts: ElementFacts, children: [WebNode] = []) {
        self.facts = facts
        self.children = children
    }
}

// MARK: - Pure web-scoped digest

/// The page-scoped digest: the role used to detect the page root, the keep rule
/// (which page elements are meaningful), the chrome filter (locate AXWebArea
/// subtrees and discard everything outside them), and the render. All pure.
public enum WebDigest {
    /// The page-root role. A browser window's page content lives under the first
    /// node of this role; its descendants are the page, its siblings are chrome.
    public static let webAreaRole = "AXWebArea"

    /// Interactive page-control roles we surface in the digest. These are the
    /// things a web automation acts on (links, buttons, fields, popups, etc).
    public static let interactiveRoles: Set<String> = [
        "AXLink", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXSlider", "AXStepper", "AXIncrementor", "AXDisclosureTriangle",
        "AXTab", "AXTabButton", "AXSegmentedControl", "AXSwitch", "AXToggle",
    ]

    /// Meaningful-text page roles. A heading or a paragraph of static text is
    /// context the brain needs to read the page; structural groups / web areas /
    /// scroll areas are NOT surfaced as content (they only host children).
    public static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading",
    ]

    /// The element's CONTENT label — title, else identifier, else value, else
    /// description text. Deliberately does NOT fall through to the role
    /// (`SnapshotRender.displayName` does), so an empty static-text node — which
    /// carries a role but no real text — reports nil here and is dropped as
    /// noise rather than rendered as the bare word "StaticText".
    public static func contentLabel(_ f: ElementFacts) -> String? {
        for candidate in [f.title, f.identifier, f.value, f.descriptionText] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// True iff this element is a meaningful page node to KEEP in the digest —
    /// an interactive control OR a meaningful-text node that actually carries a
    /// non-empty label/value. Structural containers (AXGroup, AXWebArea,
    /// AXScrollArea, …) are dropped; they are only walked THROUGH for children.
    public static func isMeaningful(_ f: ElementFacts) -> Bool {
        guard let role = f.role else { return false }
        if interactiveRoles.contains(role) { return true }
        if textRoles.contains(role) {
            // Honest: an empty static-text node is noise, not content. Keep it
            // only when it has a real label/value to show — NOT just a role.
            return contentLabel(f) != nil
        }
        return false
    }

    // MARK: Chrome filter — locate the page subtrees

    /// Collect the AXWebArea subtree roots from a raw browser forest. This IS the
    /// chrome filter: everything reachable only OUTSIDE an AXWebArea (the
    /// toolbar, the address bar, the tab group, bookmarks, window furniture) is
    /// not returned, so it is excluded by construction — not by an after-the-fact
    /// blocklist. Descends through chrome to find the page root, then stops
    /// descending once an AXWebArea is found (its descendants are all page, so a
    /// nested web area — an iframe — is kept as part of the same page subtree
    /// rather than split out as a second page).
    public static func webAreaRoots(in forest: [WebNode]) -> [WebNode] {
        var roots: [WebNode] = []
        func walk(_ node: WebNode) {
            if node.facts.role == webAreaRole {
                roots.append(node)
                return // stop: descendants are page content, kept via this root
            }
            for child in node.children { walk(child) }
        }
        for root in forest { walk(root) }
        return roots
    }

    // MARK: Digest build — keep meaningful page nodes, preserve nesting

    /// One rendered digest entry: a kept page node, its facts, and its depth
    /// RELATIVE to the page (the AXWebArea root is depth 0's parent; its first
    /// kept descendants are depth 0). Nesting among kept nodes is preserved so a
    /// list inside a nav inside the page reads as a tree, not a flat dump.
    public struct Entry: Sendable, Equatable {
        public var facts: ElementFacts
        public var depth: Int
        public init(facts: ElementFacts, depth: Int) {
            self.facts = facts
            self.depth = depth
        }
    }

    /// The pure digest: walk each AXWebArea subtree, emit only `isMeaningful`
    /// page nodes, and assign each kept node a depth equal to the number of kept
    /// ANCESTORS above it (so structural containers we skip don't inflate the
    /// indent, but a kept nav → kept link relationship is preserved). The
    /// AXWebArea root itself is never emitted (it is the scope, not content).
    public static func entries(forPage roots: [WebNode]) -> [Entry] {
        var out: [Entry] = []
        func walk(_ node: WebNode, keptDepth: Int) {
            if isMeaningful(node.facts) {
                out.append(Entry(facts: node.facts, depth: keptDepth))
                for child in node.children { walk(child, keptDepth: keptDepth + 1) }
            } else {
                // Skip this structural node but keep walking through it; kept
                // descendants attach at the same depth (the container vanishes).
                for child in node.children { walk(child, keptDepth: keptDepth) }
            }
        }
        for root in roots {
            // The AXWebArea root is the scope — don't emit it, walk its children.
            for child in root.children { walk(child, keptDepth: 0) }
        }
        return out
    }

    /// Build the page digest entries straight from a raw browser forest:
    /// chrome-filter to the AXWebArea roots, then keep meaningful page nodes.
    public static func entries(in forest: [WebNode]) -> [Entry] {
        entries(forPage: webAreaRoots(in: forest))
    }

    // MARK: Render

    /// One indented digest line, e.g. `  AXLink "Sign in"` — the role is always
    /// shown, the accessible name quoted when present, a distinct value appended,
    /// a disabled control flagged. Reuses `SnapshotRender.displayName` so the
    /// web name precedence matches the rest of the kit.
    public static func line(_ entry: Entry) -> String {
        let indent = String(repeating: "  ", count: entry.depth)
        let role = entry.facts.role ?? "AXUnknown"
        var parts = [role]
        let name = SnapshotRender.displayName(entry.facts)
        if let name, name != role {
            parts.append(name.debugDescription)
        }
        if let value = entry.facts.value, !value.isEmpty, name != value {
            parts.append("value=\(value.debugDescription)")
        }
        if entry.facts.enabled == false { parts.append("(disabled)") }
        return indent + parts.joined(separator: " ")
    }

    /// The full page digest as indented text (pre-order). Empty when the page
    /// has no meaningful controls/text — HONEST, never a fabricated placeholder.
    public static func render(_ entries: [Entry]) -> String {
        entries.map(line).joined(separator: "\n")
    }

    /// Total kept-node count for the honest "N page elements" footer.
    public static func count(_ entries: [Entry]) -> Int { entries.count }
}

// MARK: - Pure tab extraction

/// One open browser tab read off the AXTabGroup: its label and whether it is the
/// selected (frontmost) tab. Pure value type so the extractor is unit-tested
/// over fabricated tab facts.
public struct WebTab: Sendable, Equatable {
    public var title: String
    public var selected: Bool
    public init(title: String, selected: Bool) {
        self.title = title
        self.selected = selected
    }
}

/// Pure tab extraction over a raw browser forest. HONEST: an `AXTabGroup` whose
/// tabs are not exposed (no tab children) yields nil — the caller REFUSES rather
/// than guessing.
public enum WebTabs {
    /// The container role holding the tab strip, and the per-tab roles a browser
    /// uses (Chromium/Safari expose tabs as AXRadioButton; some surfaces use
    /// AXTab). Anything else under the group is ignored.
    public static let tabGroupRole = "AXTabGroup"
    public static let tabRoles: Set<String> = ["AXRadioButton", "AXTab"]

    /// Find the first AXTabGroup node in the forest, or nil if none is exposed.
    /// The tab strip lives in the window chrome (typically inside the AXToolbar),
    /// so — unlike the page digest — we DO descend chrome to reach it.
    public static func tabGroup(in forest: [WebNode]) -> WebNode? {
        func walk(_ node: WebNode) -> WebNode? {
            if node.facts.role == tabGroupRole { return node }
            for child in node.children {
                if let hit = walk(child) { return hit }
            }
            return nil
        }
        for root in forest {
            if let hit = walk(root) { return hit }
        }
        return nil
    }

    /// True iff a tab's facts report it as the selected tab. A selected
    /// AXRadioButton/AXTab reports a truthy AXValue ("1" / "true" / "selected")
    /// — read via the robust value path. We treat any of those as selected and
    /// everything else (incl. nil / "0" / "") as not selected.
    public static func isSelected(_ f: ElementFacts) -> Bool {
        guard let v = f.value?.lowercased() else { return false }
        return v == "1" || v == "true" || v == "selected" || v == "yes"
    }

    /// A human label for a tab — its title, else identifier, else description.
    /// Deliberately EXCLUDES the AXValue: a tab's value is its selected-state
    /// ("1"/"0"), not a name, so falling back to it would label a selected,
    /// title-less tab "1". An unlabelled-but-present tab gets a placeholder so it
    /// is still counted honestly.
    public static func label(_ f: ElementFacts) -> String {
        for candidate in [f.title, f.identifier, f.descriptionText, f.roleDescription] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return "(untitled tab)"
    }

    /// Extract the open tabs from a raw browser forest.
    ///
    /// Returns nil — the REFUSE signal — when there is no AXTabGroup at all, or
    /// the group exposes no tab children. A non-nil (possibly empty-after-filter
    /// is impossible here; tabs only returns when there is at least one) array is
    /// the honest tab list. Tab order follows the AX child order.
    public static func tabs(in forest: [WebNode]) -> [WebTab]? {
        guard let group = tabGroup(in: forest) else { return nil }
        let tabNodes = group.children.filter { tabRoles.contains($0.facts.role ?? "") }
        guard !tabNodes.isEmpty else { return nil }
        return tabNodes.map { WebTab(title: label($0.facts), selected: isSelected($0.facts)) }
    }
}

// MARK: - AX-touching walk (the only impure step)

/// Builds a raw `WebNode` forest from a live browser app element. Mirrors
/// `SnapshotWalker`: drives the top level from `windows()`, recurses with raw
/// `children(strict: true)` (a true parent → child tree, not the over-collecting
/// search funnel), with the same depth cap + visited-set discipline. The result
/// is a pure tree handed to the pure `WebDigest` / `WebTabs` functions.
@MainActor
enum WebWalker {
    static let maxDepth = 80

    /// Wake a browser's lazily-built web a11y tree BEFORE we walk it.
    ///
    /// Chromium (and other AX-savvy apps) build the web AXWebArea / AXTabGroup
    /// tree on demand: a cold window only exposes browser chrome until an
    /// accessibility client asks for the page. Setting `AXManualAccessibility`
    /// on the app's AX APPLICATION element is Chromium's documented opt-in that
    /// makes the browser publish the page tree.
    ///
    /// We DELIBERATELY set ONLY `AXManualAccessibility`, not
    /// `AXEnhancedUserInterface`. Enhanced-UI is an AppKit-wide flag that forces
    /// an alternate UI mode and is a known cause of layout/perf side-effects in
    /// AppKit/Electron apps; since there is no bundle-id allowlist, a `web read`
    /// against a non-Chromium app (an Electron editor, Safari, …) would mutate
    /// that live app's UI mode as a side-effect of a READ. `AXManualAccessibility`
    /// is the narrow, Chromium-specific a11y opt-in: non-Chromium apps simply
    /// refuse it (no-op), so the wake stays a targeted no-side-effect nudge.
    ///
    /// Best-effort and ADDITIVE to honesty, never a guarantee:
    ///  - We pass `true` directly; AXorcist's `setValue` bridges Swift `Bool`
    ///    to `CFBoolean` (Element.swift), so the raw-string attribute sets.
    ///  - The attribute is a raw AX string (NOT in `AXAttributeNames`), so we
    ///    use a string literal.
    ///  - The `Bool` result is IGNORED with `_ =`. A non-browser app simply
    ///    refuses the set (no-op); a refusal must NOT break the honest read.
    ///    Waking only adds a CHANCE that the subsequent walk finds a page — if
    ///    the tree is still empty after waking, the caller reports that honestly.
    ///
    /// Call on the LIVE AX application element (the `Element` wrapping
    /// `AXUIElementCreateApplication(pid)`) before the first walk AND on any
    /// freshly-rebuilt app element in a settle/retry — a brand-new
    /// `AXUIElement` does not inherit the manual-accessibility flag.
    static func wakeAccessibility(_ app: Element) {
        _ = app.setValue(true, forAttribute: "AXManualAccessibility")
    }

    static func forest(of appRoot: Element) -> [WebNode] {
        let windows = appRoot.windows() ?? []
        var visited = Set<Element>()
        return windows.map { node(from: $0, visited: &visited, depth: 0) }
    }

    private static func node(from element: Element, visited: inout Set<Element>,
                             depth: Int) -> WebNode {
        let facts = Finder.facts(of: element)
        guard depth < maxDepth, !visited.contains(element) else {
            return WebNode(facts: facts)
        }
        visited.insert(element)
        let kids = element.children(strict: true) ?? []
        return WebNode(facts: facts,
                       children: kids.map { node(from: $0, visited: &visited, depth: depth + 1) })
    }
}

// MARK: - Public entry points

extension GhostHands {
    /// A `web read` result handed to the CLI: the resolved browser name, the
    /// page digest entries, and a count.
    public struct WebReadResult: Sendable {
        public let app: String
        public let entries: [WebDigest.Entry]
        public var count: Int { WebDigest.count(entries) }
        /// True when the browser exposed at least one AXWebArea (a page is
        /// present). False means no page surface was found — the CLI reports
        /// that honestly rather than a bare empty digest.
        public let hasWebArea: Bool
    }

    /// Read the browser's focused page as a web-scoped digest — chrome stripped,
    /// AX only, no press, no focus steal.
    ///
    /// Honesty: emits only what is under an AXWebArea. Chromium builds its page
    /// AX tree lazily, so a cold window's first read can be near-empty chrome
    /// with no web area; we settle once and re-read a fresh app element before
    /// concluding the page is empty. A page that is genuinely empty stays empty.
    @MainActor
    public static func webRead(browser: String,
                               settle: TimeInterval = 0.8) throws -> WebReadResult {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(browser)

        // Wake the lazily-built web a11y tree before the first walk (no-op on
        // non-browsers; best-effort, result ignored).
        WebWalker.wakeAccessibility(target.element)
        var forest = WebWalker.forest(of: target.element)
        var roots = WebDigest.webAreaRoots(in: forest)
        // Sparse-tree retry: no web area OR a web area with no kept content can be
        // a lazily-built tree a beat before it fills. Settle once and re-read on a
        // fresh app element — which must be woken again (a brand-new AXUIElement
        // does not inherit the manual-accessibility flag).
        if (roots.isEmpty || WebDigest.entries(forPage: roots).isEmpty), settle > 0 {
            Thread.sleep(forTimeInterval: settle)
            let fresh = Element(AXUIElementCreateApplication(target.pid))
            WebWalker.wakeAccessibility(fresh)
            forest = WebWalker.forest(of: fresh)
            roots = WebDigest.webAreaRoots(in: forest)
        }
        let entries = WebDigest.entries(forPage: roots)
        return WebReadResult(app: target.name, entries: entries, hasWebArea: !roots.isEmpty)
    }

    /// A `web tabs` result handed to the CLI: the browser name and the tab list.
    public struct WebTabsResult: Sendable {
        public let app: String
        public let tabs: [WebTab]
    }

    /// List the browser's open tabs from the AXTabGroup.
    ///
    /// Honesty: if no AXTabGroup is exposed (or it lists no tabs), this throws
    /// `tabsNotExposed` so the CLI can REFUSE clearly — it never guesses or
    /// fabricates a tab list.
    @MainActor
    public static func webTabs(browser: String,
                               settle: TimeInterval = 0.6) throws -> WebTabsResult {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(browser)

        // Wake the lazily-built tree before the first walk (no-op on
        // non-browsers; best-effort, result ignored). A cold wake may need a
        // beat to publish the AXTabGroup, so the settle below covers that.
        WebWalker.wakeAccessibility(target.element)
        var forest = WebWalker.forest(of: target.element)
        var tabs = WebTabs.tabs(in: forest)
        if tabs == nil, settle > 0 {
            Thread.sleep(forTimeInterval: settle)
            let fresh = Element(AXUIElementCreateApplication(target.pid))
            WebWalker.wakeAccessibility(fresh)
            forest = WebWalker.forest(of: fresh)
            tabs = WebTabs.tabs(in: forest)
        }
        guard let tabs else { throw GhostHandsError.tabsNotExposed(app: target.name) }
        return WebTabsResult(app: target.name, tabs: tabs)
    }
}
