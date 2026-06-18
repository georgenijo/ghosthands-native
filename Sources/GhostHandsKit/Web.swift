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
        // WHERE — only ACTIONABLE controls carry coordinates. The point of the
        // frame is pixel-TARGETING a control; static text/headings are read for
        // context, not clicked, so tagging them with coords buries the signal and
        // is omitted by design (NOT a hidden missing frame). For an interactive
        // role: a real AX frame renders as @(x,y w×h); a control whose AX exposes
        // no position/size is MARKED "frame:?" — honest, never a fabricated box.
        if interactiveRoles.contains(role) {
            if let frame = entry.facts.frame {
                parts.append(frameString(frame))
            } else {
                parts.append("frame:?")
            }
        }
        return indent + parts.joined(separator: " ")
    }

    /// A coordinate token for a control's on-screen frame, e.g. `@(412,240 86×32)`.
    /// The leading `@` sigil keeps a coordinate visually distinct from `value=…`
    /// and from content, so it can never be misread as the element's text. Mirrors
    /// the repo's existing `(x,y w×h)` rect convention (PixelClick.rectString).
    public static func frameString(_ r: CGRect) -> String {
        "@(\(Int(r.minX.rounded())),\(Int(r.minY.rounded())) \(Int(r.width.rounded()))×\(Int(r.height.rounded())))"
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

// MARK: - CDP lens + pure CDP digest shaping

/// Which lens serves a `web read` / `web tabs`. `auto` prefers CDP when a debug
/// port is reachable on a browser surface and SILENTLY falls back to the existing
/// AX path otherwise (no regression, no refuse). `cdp` FORCES CDP — a closed port
/// REFUSES. `ax` always takes the existing AX path and never probes a port.
public enum WebLens: Sendable, Equatable {
    case auto
    case cdp
    case ax
}

/// The routing signal, ported from the Python `route_surface` bundle-id hint: a
/// PURE test on the target's bundle identifier. A native app (no browser hint)
/// NEVER probes a CDP port — it goes straight to AX. (The AXWebArea second branch
/// is omitted in Slice 1's auto-probe to avoid a full AX walk just to decide
/// whether to probe a port; it can join a later slice.)
public enum WebSurface {
    static let browserBundleHints = [
        "brave", "chrom", "safari", "edgemac", "firefox", "webkit",
        "vivaldi", "arc", "opera",
    ]

    /// True iff `bundleID` looks like a browser (a substring hint match). nil
    /// (no bundle id) is NOT a browser — a CDP probe is skipped.
    public static func isBrowserSurface(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return browserBundleHints.contains { id.contains($0) }
    }
}

/// PURE shaping of a `Runtime.evaluate` DOM-digest result (a JSON array of
/// `{role,name,value,x,y,w,h}` objects) into `WebDigest.Entry` values, so the CDP
/// read renders through the SAME line/render path as the AX digest. Unit-testable
/// over a fabricated `[[String:Any]]` — no socket, no browser.
///
/// HONESTY: returns only the rows the DOM actually exposed; an empty array shapes
/// to `[]` (honest empty), never a fabricated entry. Slice 1's digest is flat
/// (depth 0) — the richer nested ref model lands in a later slice.
public enum CDPDigest {
    /// The DOM-digest expression evaluated in the page. Collects interactive +
    /// text nodes with their accessible name, value, and bounding box. Kept small
    /// and `returnByValue`-friendly. (Slice 1 keeps this minimal; Slice 2+ grows
    /// the ref/snapshot model.)
    public static let evaluateExpression = """
    (() => {
      const out = [];
      const wanted = ['a','button','input','select','textarea','h1','h2','h3','h4','h5','h6'];
      for (const el of document.querySelectorAll(wanted.join(','))) {
        const r = el.getBoundingClientRect();
        const role = el.getAttribute('role') || el.tagName.toLowerCase();
        const name = (el.getAttribute('aria-label') || el.innerText || el.value || '').trim().slice(0, 200);
        out.push({ role, name, value: (el.value || '').slice(0, 200),
                   x: r.x, y: r.y, w: r.width, h: r.height });
      }
      return out;
    })()
    """

    /// Map one tag/role string to the AX-ish role the existing digest renders
    /// (so a CDP line reads like an AX line). Unknown tags pass through verbatim.
    public static func axRole(for role: String) -> String {
        switch role.lowercased() {
        case "a", "link": return "AXLink"
        case "button": return "AXButton"
        case "input", "textbox", "textfield": return "AXTextField"
        case "textarea": return "AXTextArea"
        case "select", "combobox": return "AXComboBox"
        case "checkbox": return "AXCheckBox"
        case "radio": return "AXRadioButton"
        case "h1", "h2", "h3", "h4", "h5", "h6", "heading": return "AXHeading"
        default: return role
        }
    }

    /// Shape the `Runtime.evaluate` result array into flat digest entries. Drops
    /// rows with neither a name nor a value (noise), mirroring `WebDigest`'s
    /// drop-empty rule. Each row's box becomes the entry's frame so the existing
    /// renderer can tag interactive controls with `@(x,y w×h)`.
    public static func entries(fromEvaluate rows: [[String: Any]]) -> [WebDigest.Entry] {
        var out: [WebDigest.Entry] = []
        for row in rows {
            let rawRole = (row["role"] as? String) ?? "AXUnknown"
            let role = axRole(for: rawRole)
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let value = (row["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Drop a node with no name AND no value — it carries no signal.
            if name == nil && value == nil { continue }
            let frame = boundingBox(row)
            let facts = ElementFacts(role: role, title: name, value: value, frame: frame)
            out.append(WebDigest.Entry(facts: facts, depth: 0))
        }
        return out
    }

    /// A `CGRect` from a row's `x/y/w/h` numbers, or nil when any is missing /
    /// the box is zero-sized (an off-layout node) — honest "no frame", never a
    /// fabricated box.
    static func boundingBox(_ row: [String: Any]) -> CGRect? {
        guard let x = (row["x"] as? NSNumber)?.doubleValue,
              let y = (row["y"] as? NSNumber)?.doubleValue,
              let w = (row["w"] as? NSNumber)?.doubleValue,
              let h = (row["h"] as? NSNumber)?.doubleValue,
              w > 0 || h > 0
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
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

// MARK: - Lens-aware entry points (CDP ⇄ AX)

extension GhostHands {
    /// Which lens actually served a read — surfaced to the CLI for the honest
    /// "(via CDP, port N)" / "(via AX)" footer. Distinct from `WebLens` (the
    /// REQUEST): `.auto` resolves to either `.cdp` or `.ax`, never stays `.auto`.
    public enum ServedLens: Sendable, Equatable {
        case cdp(port: Int)
        case ax
    }

    /// `web read` with a lens. The EXISTING AX path stays authoritative; CDP is a
    /// parallel branch IN FRONT of it, never a replacement.
    ///
    /// THE rule: `auto && browserSurface && portOpen → CDP; else → AX`. A closed
    /// port under `auto` falls back SILENTLY to the unchanged AX path (the
    /// no-regression contract); a closed port under FORCED `.cdp` REFUSES with
    /// `cdpPortClosed` (the only place that error is thrown); FORCED `.ax` never
    /// even probes a port.
    @MainActor
    public static func webRead(browser: String, lens: WebLens,
                               debugPort: Int = 9222,
                               settle: TimeInterval = 0.8)
        async throws -> (result: WebReadResult, served: ServedLens) {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(browser)

        switch lens {
        case .ax:
            return (try webRead(browser: browser, settle: settle), .ax)
        case .cdp:
            guard await CDPDiscovery.isPortOpen(debugPort) else {
                throw GhostHandsError.cdpPortClosed(app: target.name, port: debugPort)
            }
            return (try await webReadCDP(target: target, port: debugPort), .cdp(port: debugPort))
        case .auto:
            if WebSurface.isBrowserSurface(bundleID: target.app.bundleIdentifier),
               await CDPDiscovery.isPortOpen(debugPort) {
                return (try await webReadCDP(target: target, port: debugPort),
                        .cdp(port: debugPort))
            }
            // SILENT fall-through to AX — no regression, no refuse.
            return (try webRead(browser: browser, settle: settle), .ax)
        }
    }

    /// `web tabs` with a lens. CDP's win here is listing ALL tabs incl. background
    /// ones (closing the `tabsNotExposed` gap); `/json/list` does not mark the
    /// active tab, so `selected` is honestly left false. Same auto/forced/AX rule
    /// as `webRead`.
    @MainActor
    public static func webTabs(browser: String, lens: WebLens,
                               debugPort: Int = 9222,
                               settle: TimeInterval = 0.6)
        async throws -> (result: WebTabsResult, served: ServedLens) {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(browser)

        switch lens {
        case .ax:
            return (try webTabs(browser: browser, settle: settle), .ax)
        case .cdp:
            guard await CDPDiscovery.isPortOpen(debugPort) else {
                throw GhostHandsError.cdpPortClosed(app: target.name, port: debugPort)
            }
            return (try await webTabsCDP(target: target, port: debugPort),
                    .cdp(port: debugPort))
        case .auto:
            if WebSurface.isBrowserSurface(bundleID: target.app.bundleIdentifier),
               await CDPDiscovery.isPortOpen(debugPort) {
                return (try await webTabsCDP(target: target, port: debugPort),
                        .cdp(port: debugPort))
            }
            return (try webTabs(browser: browser, settle: settle), .ax)
        }
    }

    // MARK: CDP-backed reads (impure thin — pure shaping in CDPDigest/CDPTarget)

    /// Read the page via CDP: open a session to the browser-level socket, then
    /// `Runtime.enable` + `Runtime.evaluate` the DOM-digest expression. HONEST:
    /// returns only the DOM the page actually exposed; an empty page reads empty.
    /// Slice 1's digest is flat (point-in-time, no nested refs).
    @MainActor
    static func webReadCDP(target: Target, port: Int) async throws -> WebReadResult {
        // Connect to a PAGE target's OWN debugger socket, not the browser-level
        // /json/version endpoint — the browser endpoint has no Runtime domain
        // (it answers "Runtime.enable wasn't found"). Slice 1 reads the FIRST
        // debuggable page target; per-tab selection (by url / index) is a later
        // slice. Honest empty when the port lists no debuggable page.
        let targets = try await CDPDiscovery.list(port: port, app: target.name)
        guard let page = targets.first(where: { !$0.webSocketDebuggerUrl.isEmpty }) else {
            return WebReadResult(app: target.name, entries: [], hasWebArea: false)
        }
        let session = try CDPSession.open(wsURL: page.webSocketDebuggerUrl)
        _ = try await session.call("Runtime.enable")
        let result = try await session.call("Runtime.evaluate", params: [
            "expression": CDPDigest.evaluateExpression,
            "returnByValue": true,
            "awaitPromise": true,
        ])
        let rows = evaluateRows(from: result)
        let entries = CDPDigest.entries(fromEvaluate: rows)
        // A reachable CDP page IS a web surface (hasWebArea = true), so the CLI
        // footer reports element count rather than "no page".
        return WebReadResult(app: target.name, entries: entries, hasWebArea: true)
    }

    /// Pull the `[[String:Any]]` array out of a `Runtime.evaluate` reply's
    /// `{result:{value:[…]}}` shape. Honest empty `[]` when the page returned a
    /// non-array (or nothing) — never a fabricated row.
    static func evaluateRows(from reply: [String: Any]) -> [[String: Any]] {
        guard let resultObj = reply["result"] as? [String: Any],
              let value = resultObj["value"] as? [Any] else { return [] }
        return value.compactMap { $0 as? [String: Any] }
    }

    /// List ALL tabs via CDP `/json/list` (incl. background tabs AX can't see).
    /// `selected` is honestly false — `/json/list` does not mark the active tab.
    @MainActor
    static func webTabsCDP(target: Target, port: Int) async throws -> WebTabsResult {
        let targets = try await CDPDiscovery.list(port: port, app: target.name)
        let tabs = targets.map { t -> WebTab in
            let title = t.title.isEmpty ? (t.url.isEmpty ? "(untitled tab)" : t.url) : t.title
            return WebTab(title: title, selected: false)
        }
        return WebTabsResult(app: target.name, tabs: tabs)
    }
}
