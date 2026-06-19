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
    /// Interactive-control STATE surfaced inline by `web read` (issue #8) so a
    /// checkbox/radio/select toggle is verifiable in ONE read — no `web eval`. Only
    /// the CDP read populates it (the JS probe reads the live DOM state); the AX
    /// path leaves it nil. Each field is OPTIONAL and rendered only when present, so
    /// a control that has no such state stays clean.
    public struct ControlState: Sendable, Equatable {
        /// A checkbox/radio's checked state (nil for non-checkable controls).
        public var checked: Bool?
        /// A `<select>`'s currently-chosen option text (nil when not a select).
        public var selected: String?
        /// `aria-expanded` for a combobox/disclosure (nil when not exposed).
        public var expanded: Bool?
        public init(checked: Bool? = nil, selected: String? = nil, expanded: Bool? = nil) {
            self.checked = checked
            self.selected = selected
            self.expanded = expanded
        }
        /// True iff this carries any real state — used by the digest keep rule so a
        /// stateful-but-unlabeled control (a bare checkbox) is NOT dropped as noise.
        public var hasSignal: Bool { checked != nil || selected != nil || expanded != nil }
    }

    public struct Entry: Sendable, Equatable {
        public var facts: ElementFacts
        public var depth: Int
        /// The shared `@eN` ref handle stamped on this interactive element at read
        /// time (the fast everyday addressing path: `web read` prints it, `web
        /// click/fill @eN` resolves it). Nil for non-interactive (text/heading)
        /// entries and for the AX read path — which can't stamp the live DOM, so
        /// only the CDP read populates refs. A ref resolves back to the element via
        /// the `data-gh-ref` attribute the read wrote; a navigation/re-render that
        /// removes that attribute makes the ref REFUSE ("stale ref") at action time.
        public var ref: String?
        /// Inline form-control state (issue #8) — nil for non-form entries and the
        /// AX read path; populated only by the CDP read from the live DOM.
        public var state: ControlState?
        public init(facts: ElementFacts, depth: Int, ref: String? = nil,
                    state: ControlState? = nil) {
            self.facts = facts
            self.depth = depth
            self.ref = ref
            self.state = state
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
        // The `@eN` ref (when present) LEADS the line so look and click share one
        // handle: read prints `@e5 AXLink "Sign in" @(…)`, then `web click @e5`.
        // Distinct from the trailing `@(x,y w×h)` frame token (paren, not `eN`).
        var parts: [String] = []
        if let ref = entry.ref { parts.append(ref) }
        parts.append(role)
        let name = SnapshotRender.displayName(entry.facts)
        if let name, name != role {
            parts.append(name.debugDescription)
        }
        if let value = entry.facts.value, !value.isEmpty, name != value {
            parts.append("value=\(value.debugDescription)")
        }
        // Inline form-control STATE (issue #8): each token shown only when present,
        // so a checkbox reads `checked=true`, a select `selected="United States"`, a
        // disclosure `expanded=false` — verifiable in one read, no `web eval`.
        if let st = entry.state {
            if let checked = st.checked { parts.append("checked=\(checked)") }
            if let selected = st.selected, !selected.isEmpty {
                parts.append("selected=\(selected.debugDescription)")
            }
            if let expanded = st.expanded { parts.append("expanded=\(expanded)") }
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
    /// JS defining `accName(el, tag)` — derives an element's ACCESSIBLE NAME from
    /// REAL sources only, in priority order, never fabricated: `aria-label` → an
    /// associated `<label for=id>` → a wrapping `<label>` → the element's own
    /// innerText → `placeholder` → the form-control `name` attribute. Shared by the
    /// page and scoped digests so a label-wrapped control (e.g. httpbin's bare
    /// "Customer name:" input) reads WITH a name instead of blank — matching what a
    /// screen reader and agent-browser's snapshot surface. All lookups are guarded
    /// (try/optional) so a missing CSS.escape / detached node degrades to "" rather
    /// than throwing the whole digest.
    static let accNameJS = """
    const accName = (el, tag) => {
      let nm = (el.getAttribute('aria-label') || '').trim();
      if (!nm && el.id) {
        try {
          const key = (window.CSS && CSS.escape) ? CSS.escape(el.id) : el.id;
          const l = document.querySelector('label[for="' + key + '"]');
          if (l) nm = (l.innerText || '').trim();
        } catch (e) {}
      }
      if (!nm && el.closest) { const w = el.closest('label'); if (w) nm = (w.innerText || '').trim(); }
      if (!nm) nm = (el.innerText || '').trim();
      if (!nm) nm = (el.getAttribute('placeholder') || '').trim();
      if (!nm) nm = (el.getAttribute('name') || '').trim();
      return nm.slice(0, 200);
    };
    """

    /// The DOM-digest expression evaluated in the page. Collects interactive +
    /// text nodes with their accessible name, value, and bounding box. Kept small
    /// and `returnByValue`-friendly. (Slice 1 keeps this minimal; Slice 2+ grows
    /// the ref/snapshot model.)
    public static let evaluateExpression = """
    (() => {
      // Clear any `data-gh-ref` from a PRIOR read first: refs are valid only until
      // the next read or a navigation, so a re-read SUPERSEDES — old handles must
      // not linger and collide with the new numbering.
      for (const el of document.querySelectorAll('[data-gh-ref]')) el.removeAttribute('data-gh-ref');
      \(accNameJS)
      const out = [];
      const interactive = ['a','button','input','select','textarea'];
      const text = ['h1','h2','h3','h4','h5','h6'];
      const wanted = interactive.concat(text);
      let n = 0;
      for (const el of document.querySelectorAll(wanted.join(','))) {
        const r = el.getBoundingClientRect();
        const tag = el.tagName.toLowerCase();
        const type = ((el.getAttribute && el.getAttribute('type')) || '').toLowerCase();
        // Role: an explicit aria role wins; else the tag — but an <input> is
        // refined by its type so a checkbox/radio reads as one (not a text field).
        let role = el.getAttribute('role');
        if (!role) {
          role = (tag === 'input')
            ? ((type === 'checkbox') ? 'checkbox' : (type === 'radio') ? 'radio' : 'input')
            : tag;
        }
        const name = accName(el, tag);
        // Stamp a shared ref on INTERACTIVE elements only (headings are read for
        // context, never clicked). The attribute IS the persistent ref store: it
        // lives in the browser's DOM across separate CLI processes, and its
        // absence after a nav/re-render is the honest staleness signal.
        let ref = '';
        if (interactive.includes(tag)) { ref = 'e' + (++n); el.setAttribute('data-gh-ref', ref); }
        // Form-control STATE (issue #8). A checkbox/radio's signal is `checked`,
        // NOT its meaningless default value "on" — so we emit checked and leave
        // value empty for those. A <select> reports its chosen option's text.
        let value = '', checked = null, selected = null, expanded = null;
        if (tag === 'input' && (type === 'checkbox' || type === 'radio')) {
          checked = !!el.checked;
        } else if (tag === 'select') {
          const o = el.options && el.options[el.selectedIndex];
          selected = o ? (o.text || o.value || '') : '';
          value = (el.value || '').slice(0, 200);
        } else {
          value = (el.value || '').slice(0, 200);
        }
        const axExp = el.getAttribute && el.getAttribute('aria-expanded');
        if (axExp === 'true' || axExp === 'false') expanded = (axExp === 'true');
        const disabled = !!el.disabled;
        out.push({ ref, role, name, value, checked, selected, expanded, disabled,
                   x: r.x, y: r.y, w: r.width, h: r.height });
      }
      return out;
    })()
    """

    /// The SCOPED digest expression (`web read --in <css>`, issue #11): the same
    /// per-element collection as `evaluateExpression`, but rooted at the first
    /// element matching `container` instead of the whole document. Returns
    /// `{ found, rows }` so the caller can REFUSE honestly when the container
    /// selector matches nothing (vs an honest empty digest for a present-but-empty
    /// container). Refs are still stamped (so you can click within the scope).
    public static func scopedEvaluateExpression(container: String) -> String {
        let sel = WebActuate.jsonStringLiteral(container)
        return """
        (() => {
          let root;
          try { root = document.querySelector(\(sel)); } catch (e) { root = null; }
          if (!root) return { found: false };
          for (const el of document.querySelectorAll('[data-gh-ref]')) el.removeAttribute('data-gh-ref');
          \(accNameJS)
          const out = [];
          const interactive = ['a','button','input','select','textarea'];
          const text = ['h1','h2','h3','h4','h5','h6'];
          const wanted = interactive.concat(text);
          let n = 0;
          for (const el of root.querySelectorAll(wanted.join(','))) {
            const r = el.getBoundingClientRect();
            const tag = el.tagName.toLowerCase();
            const type = ((el.getAttribute && el.getAttribute('type')) || '').toLowerCase();
            let role = el.getAttribute('role');
            if (!role) {
              role = (tag === 'input')
                ? ((type === 'checkbox') ? 'checkbox' : (type === 'radio') ? 'radio' : 'input')
                : tag;
            }
            const name = accName(el, tag);
            let ref = '';
            if (interactive.includes(tag)) { ref = 'e' + (++n); el.setAttribute('data-gh-ref', ref); }
            let value = '', checked = null, selected = null, expanded = null;
            if (tag === 'input' && (type === 'checkbox' || type === 'radio')) {
              checked = !!el.checked;
            } else if (tag === 'select') {
              const o = el.options && el.options[el.selectedIndex];
              selected = o ? (o.text || o.value || '') : '';
              value = (el.value || '').slice(0, 200);
            } else {
              value = (el.value || '').slice(0, 200);
            }
            const axExp = el.getAttribute && el.getAttribute('aria-expanded');
            if (axExp === 'true' || axExp === 'false') expanded = (axExp === 'true');
            const disabled = !!el.disabled;
            out.push({ ref, role, name, value, checked, selected, expanded, disabled,
                       x: r.x, y: r.y, w: r.width, h: r.height });
          }
          return { found: true, rows: out };
        })()
        """
    }

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
            // Form-control state (issue #8) — checked/selected/expanded, plus
            // disabled folded into `enabled` so the existing "(disabled)" renders.
            let state = WebDigest.ControlState(
                checked: WebActuate.optBool(row["checked"]),
                selected: (row["selected"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                expanded: WebActuate.optBool(row["expanded"]))
            // The read stamped a bare id ("e5") on interactive elements; surface it
            // as the `@e5` handle the digest prints and `web click/fill` accepts.
            let ref = (row["ref"] as? String).flatMap { $0.isEmpty ? nil : "@\($0)" }
            // Drop a node with no name, no value, AND no meaningful state — UNLESS it
            // carries a ref. A ref marks an INTERACTIVE control: a bare or
            // label-wrapped text input (empty pre-fill, label sits on a wrapper, not
            // the element) is fully actionable, never noise — dropping it hid fillable
            // fields from `web read`. A heading/text node has no ref and still drops.
            if ref == nil && name == nil && value == nil && !state.hasSignal { continue }
            let frame = boundingBox(row)
            let disabled = WebActuate.boolValue(row["disabled"])
            let facts = ElementFacts(role: role, title: name, value: value,
                                     enabled: disabled ? false : nil, frame: frame)
            out.append(WebDigest.Entry(facts: facts, depth: 0, ref: ref,
                                       state: state.hasSignal ? state : nil))
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

    // MARK: Consent-gated isolated relaunch (Slice 4)

    /// Resolve the EFFECTIVE CDP port for a FORCED/selector verb, applying the
    /// consent-gated relaunch rule via the PURE `CDPLaunchDecision.decide`:
    ///
    ///   port open                       → use it (connect to the existing instance)
    ///   port closed && !relaunch        → THROW `cdpPortClosed` (unchanged default refuse)
    ///   port closed &&  relaunch        → launch a NEW, ISOLATED instance, then use
    ///                                     the OS-chosen port read from its sidecar
    ///
    /// On a relaunch, returns the launched-instance facts (binary, temp profile,
    /// chosen port) so the CLI can report EXACTLY what was launched — a relaunch is
    /// never silent. The user's real profile is NEVER touched: the new instance
    /// runs on a throwaway `--user-data-dir` under the system temp dir.
    @MainActor
    static func resolveCDPPort(target: Target, requestedPort: Int, relaunch: Bool)
        async throws -> (port: Int, launched: CDPLaunchedInstance?) {
        let portOpen = await CDPDiscovery.isPortOpen(requestedPort)
        switch CDPLaunchDecision.decide(portOpen: portOpen, relaunchRequested: relaunch) {
        case .connectExisting:
            return (requestedPort, nil)
        case .refuseClosed:
            throw GhostHandsError.cdpPortClosed(app: target.name, port: requestedPort)
        case .relaunchIsolated:
            let binary = try browserBinaryPath(for: target)
            let launched = try await CDPLauncher.launch(binaryPath: binary)
            return (launched.port, launched)
        }
    }

    /// Resolve the browser executable to relaunch from a resolved `Target`. We
    /// relaunch the SAME browser app the user named — its bundle's executable, via
    /// `NSRunningApplication.bundleURL` (the running app's real bundle on disk).
    /// Throws `relaunchFailed` when the bundle / executable can't be located, so a
    /// relaunch never spawns a guessed binary.
    @MainActor
    static func browserBinaryPath(for target: Target) throws -> String {
        guard let bundleURL = target.app.bundleURL,
              let bundle = Bundle(url: bundleURL),
              let exec = bundle.executableURL else {
            throw GhostHandsError.relaunchFailed(
                reason: "could not locate the executable of \(target.name) to relaunch")
        }
        return exec.path
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
                               relaunch: Bool = false,
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
            // Consent-gated: open port → connect; closed + --relaunch → isolated
            // relaunch on the OS-chosen port; closed without it → refuse.
            let (port, _) = try await resolveCDPPort(
                target: target, requestedPort: debugPort, relaunch: relaunch)
            return (try await webReadCDP(target: target, port: port), .cdp(port: port))
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
                               relaunch: Bool = false,
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
            let (port, _) = try await resolveCDPPort(
                target: target, requestedPort: debugPort, relaunch: relaunch)
            return (try await webTabsCDP(target: target, port: port),
                    .cdp(port: port))
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

    /// `web read --in <css>` (issue #11) — the page digest SCOPED to a container.
    /// CDP-only (a CSS scope has no AX equivalent): a `--ax` lens REFUSES via
    /// `resolveForSelectorVerb`. The container selector matching NOTHING REFUSES
    /// (`selectorNotFound`) — distinct from a present-but-empty container, which is
    /// an honest empty digest.
    @MainActor
    public static func webReadScoped(selector: String, browser: String, lens: WebLens,
                                     debugPort: Int = 9222, relaunch: Bool = false)
        async throws -> (result: WebReadResult, served: ServedLens) {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        let reply = try await evaluateObject(
            session, CDPDigest.scopedEvaluateExpression(container: selector))
        guard WebActuate.boolValue(reply["found"]) else {
            throw GhostHandsError.selectorNotFound(selector: selector, app: target.name)
        }
        let rows = (reply["rows"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let entries = CDPDigest.entries(fromEvaluate: rows)
        let result = WebReadResult(app: target.name, entries: entries, hasWebArea: true)
        return (result, .cdp(port: port))
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

// MARK: - CDP-only DOM-selector actuation (web click / web fill)

extension GhostHands {
    /// A `web click` / `web fill` result handed to the CLI: the browser name, the
    /// selector acted on, the honest verdict, and the served port (for the footer).
    public struct WebActuateResult: Sendable {
        public let app: String
        public let selector: String
        /// The action label for the verdict line ("clicked" / "filled").
        public let verb: String
        public let verdict: WebActuate.Verdict
        public let port: Int
        /// An optional honest note appended to the report — used by the
        /// see-the-words backup to say WHICH element a `--text` query picked and how
        /// many matched (so the user can `--nth` to choose another). Nil for the
        /// ref/CSS path, which addresses one element exactly.
        public let note: String?

        public init(app: String, selector: String, verb: String,
                    verdict: WebActuate.Verdict, port: Int, note: String? = nil) {
            self.app = app
            self.selector = selector
            self.verb = verb
            self.verdict = verdict
            self.port = port
            self.note = note
        }

        /// True only when an observed world-change proved the actuation.
        public var verified: Bool {
            if case .verified = verdict { return true }
            return false
        }
    }

    /// Resolve the first debuggable PAGE target's socket on `port`, exactly like
    /// `webReadCDP`. Throws `cdpTransport` (NOT `selectorNotFound`) when the port
    /// lists NO debuggable page — that is a no-page-surface condition, not a wrong
    /// selector (the selector is never probed here), so attributing it to the
    /// selector would lie about the cause. `cdpPortClosed` is raised earlier (by
    /// `resolveForSelectorVerb`) when the port itself is unreachable.
    @MainActor
    static func openPageSession(target: Target, port: Int)
        async throws -> CDPSession {
        let targets = try await CDPDiscovery.list(port: port, app: target.name)
        guard let page = targets.first(where: { !$0.webSocketDebuggerUrl.isEmpty }) else {
            throw GhostHandsError.cdpTransport(
                reason: "no debuggable page target on port \(port) for "
                    + "\(target.name) — open a tab to actuate")
        }
        let session = try CDPSession.open(wsURL: page.webSocketDebuggerUrl)
        _ = try await session.call("Runtime.enable")
        return session
    }

    /// `web click <selector>` over CDP. ONE probe (occlusion + geometry), the pure
    /// `clickDecision` gate, then — on `.proceed` — a TRUSTED click via
    /// `Input.dispatchMouseEvent`, verified by an href change.
    ///
    ///   .notFound → throw `selectorNotFound`
    ///   .covered  → throw `elementCovered` (refuse: never click through an overlay)
    ///   .proceed  → read href, dispatch mousePressed+mouseReleased at the center,
    ///               read href again. Changed → VERIFIED (navigation); else
    ///               dispatched-unverified.
    @MainActor
    public static func webClick(selector: String, browser: String, lens: WebLens,
                                debugPort: Int = 9222, relaunch: Bool = false)
        async throws -> WebActuateResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)

        // Resolve an `@eN` ref to its `data-gh-ref` selector (CSS passes through).
        let resolved = WebRef.resolve(selector)
        // ONE occlusion + geometry probe, returned by value, decided PURELY.
        let probe = try await evaluateObject(
            session, WebActuate.probeExpression(selector: resolved.selector))
        switch WebActuate.clickDecision(from: probe) {
        case .notFound:
            // A ref that matches nothing = the stamped element moved → stale, not a
            // bad selector. REFUSE distinctly so the caller re-reads, never retargets.
            if resolved.isRef { throw GhostHandsError.staleRef(ref: selector) }
            throw GhostHandsError.selectorNotFound(selector: selector, app: target.name)
        case let .covered(by):
            throw GhostHandsError.elementCovered(selector: selector, coveredBy: by)
        case let .proceed(center, _):
            let hrefBefore = try await readLocationHref(session)
            try await dispatchTrustedClick(session, at: center)
            let verdict = try await postClickVerdict(session, hrefBefore: hrefBefore)
            return WebActuateResult(app: target.name, selector: selector,
                                    verb: "clicked", verdict: verdict, port: port)
        }
    }

    /// `web fill <selector> <text>` over CDP. ONE probe to confirm the element
    /// exists and is not a SECURE field, then focus + set the value + dispatch
    /// input/change, verified by reading the value back.
    ///
    ///   not found → throw `selectorNotFound`
    ///   isSecure  → throw `secureFieldUnverifiable` (value can't be read back)
    ///   else      → el.focus(); el.value = text; dispatch input+change; read back.
    ///               readback == text → VERIFIED; else dispatched-unverified.
    @MainActor
    public static func webFill(selector: String, text: String, browser: String,
                               lens: WebLens, debugPort: Int = 9222,
                               relaunch: Bool = false)
        async throws -> WebActuateResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)

        // Resolve an `@eN` ref to its `data-gh-ref` selector (CSS passes through).
        let resolved = WebRef.resolve(selector)
        let probe = try await evaluateObject(
            session, WebActuate.probeExpression(selector: resolved.selector))
        // A fill only needs the element to EXIST — not a usable box (a zero-box
        // input, e.g. one briefly display:none then shown, is still fillable). So
        // gate directly on `found`, NOT on `clickDecision` (which also demotes a
        // box-less element to `.notFound`, the wrong refuse for fill).
        guard WebActuate.boolValue(probe["found"]) else {
            // A ref that matches nothing = the stamped element moved → stale refuse.
            if resolved.isRef { throw GhostHandsError.staleRef(ref: selector) }
            throw GhostHandsError.selectorNotFound(selector: selector, app: target.name)
        }
        if WebActuate.isSecure(from: probe) {
            throw GhostHandsError.secureFieldUnverifiable(name: selector)
        }

        let readback = try await focusSetAndReadBack(
            session, selector: resolved.selector, text: text)
        let verdict = WebActuate.fillVerdict(intended: text, readback: readback)
        return WebActuateResult(app: target.name, selector: selector,
                                verb: "filled", verdict: verdict, port: port)
    }

    /// `web select <@eN|selector> <value>` over CDP. ONE evaluate that confirms the
    /// element is a `<select>`, matches an option by value OR visible text, sets it,
    /// fires input+change, and reads the now-selected option back. Verified by that
    /// read-back (mirrors `web fill`); never asserts a selection it can't observe.
    ///
    ///   not found     → throw `selectorNotFound` (or `staleRef` for a ref)
    ///   not a <select>→ throw `notASelect`
    ///   no match      → throw `optionNotFound` (lists the real options)
    ///   else          → selectedIndex set; read-back == request → VERIFIED, else
    ///                   dispatched-unverified.
    @MainActor
    public static func webSelect(selector: String, value: String, browser: String,
                                 lens: WebLens, debugPort: Int = 9222,
                                 relaunch: Bool = false)
        async throws -> WebActuateResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)

        // Resolve an `@eN` ref to its `data-gh-ref` selector (CSS passes through).
        let resolved = WebRef.resolve(selector)
        let result = try await evaluateObject(
            session, WebActuate.selectExpression(selector: resolved.selector, value: value))

        guard WebActuate.boolValue(result["found"]) else {
            // A ref that matches nothing = the stamped element moved → stale refuse.
            if resolved.isRef { throw GhostHandsError.staleRef(ref: selector) }
            throw GhostHandsError.selectorNotFound(selector: selector, app: target.name)
        }
        guard WebActuate.boolValue(result["isSelect"]) else {
            let role = (result["role"] as? String) ?? "element"
            throw GhostHandsError.notASelect(selector: selector, role: role)
        }
        guard WebActuate.boolValue(result["matched"]) else {
            let options = (result["options"] as? [Any])?.compactMap { $0 as? String } ?? []
            throw GhostHandsError.optionNotFound(
                value: value, selector: selector, options: options)
        }
        let verdict = WebActuate.selectVerdict(
            intended: value,
            selectedValue: result["value"] as? String,
            selectedText: result["text"] as? String)
        return WebActuateResult(app: target.name, selector: selector,
                                verb: "selected", verdict: verdict, port: port)
    }

    // MARK: See-the-words backup (web click/fill --text) — issue #7 secondary path

    /// `web click --text "<visible>" [--nth N]` — click the control a HUMAN would
    /// read as `<visible>`, re-resolved LIVE (can't go stale like a ref). Ranks ties
    /// and acts on the obvious top one (or `--nth N`), reports WHICH it picked, and
    /// verifies by navigation — the same honesty as every actuation.
    @MainActor
    public static func webClickByText(text: String, nth: Int?, browser: String,
                                      lens: WebLens, debugPort: Int = 9222,
                                      relaunch: Bool = false) async throws -> WebActuateResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        let label = try await resolveByText(session, target: target, text: text,
                                            nth: nth, fillable: false)
        // Act on the stamped pick through the SAME occlusion + verify path.
        let probe = try await evaluateObject(
            session, WebActuate.probeExpression(selector: WebFind.pickSelector))
        switch WebActuate.clickDecision(from: probe) {
        case .notFound:
            // The pick vanished between resolve and act (a re-render) — honest refuse.
            throw GhostHandsError.elementNotFound(name: text, app: target.name)
        case let .covered(by):
            throw GhostHandsError.elementCovered(selector: label.label, coveredBy: by)
        case let .proceed(center, _):
            let hrefBefore = try await readLocationHref(session)
            try await dispatchTrustedClick(session, at: center)
            let verdict = try await postClickVerdict(session, hrefBefore: hrefBefore)
            return WebActuateResult(app: target.name, selector: label.label,
                                    verb: "clicked", verdict: verdict, port: port,
                                    note: label.note)
        }
    }

    /// `web fill --text "<label>" "<value>" [--nth N]` — fill the field a human
    /// would read as labeled `<label>` (aria-label / placeholder / associated
    /// `<label>`), re-resolved live, verified by read-back.
    @MainActor
    public static func webFillByText(text: String, value: String, nth: Int?,
                                     browser: String, lens: WebLens, debugPort: Int = 9222,
                                     relaunch: Bool = false) async throws -> WebActuateResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        let label = try await resolveByText(session, target: target, text: text,
                                            nth: nth, fillable: true)
        let probe = try await evaluateObject(
            session, WebActuate.probeExpression(selector: WebFind.pickSelector))
        guard WebActuate.boolValue(probe["found"]) else {
            throw GhostHandsError.elementNotFound(name: text, app: target.name)
        }
        if WebActuate.isSecure(from: probe) {
            throw GhostHandsError.secureFieldUnverifiable(name: label.label)
        }
        let readback = try await focusSetAndReadBack(
            session, selector: WebFind.pickSelector, text: value)
        let verdict = WebActuate.fillVerdict(intended: value, readback: readback)
        return WebActuateResult(app: target.name, selector: label.label,
                                verb: "filled", verdict: verdict, port: port,
                                note: label.note)
    }

    /// Run the find resolver, classify it, and (on a hit) return the picked label +
    /// an honest note. Throws the refuse for none / out-of-range. Shared by the
    /// click + fill `--text` paths; the actual actuation stays in the callers.
    @MainActor
    static func resolveByText(_ session: CDPSession, target: Target, text: String,
                              nth: Int?, fillable: Bool)
        async throws -> (label: String, note: String?) {
        let reply = try await evaluateObject(
            session, WebFind.resolveExpression(text: text, nth: nth, fillable: fillable))
        switch WebFind.decide(reply) {
        case let .none(count):
            _ = count
            throw GhostHandsError.elementNotFound(name: text, app: target.name)
        case let .outOfRange(count):
            throw GhostHandsError.locatorIndexOutOfRange(
                name: text, requested: (nth ?? 0) + 1, count: count)
        case let .found(label, count):
            let note = "picked by text \(text.debugDescription) → \(label.debugDescription)"
                + (count > 1 ? " (\(count) matched; --nth N to choose another)" : "")
            return (label, note)
        }
    }

    // MARK: Selector-verb plumbing (impure thin)

    /// Resolve the browser AND enforce the lens contract for a selector verb. The
    /// selector verbs REQUIRE CDP: a forced `--ax` is a USAGE refuse
    /// (`selectorNeedsCDP`); `.cdp`/`.auto` both proceed on the default port. We do
    /// NOT silently fall back to AX (unlike `web read`) — there is no AX path for a
    /// CSS selector, so falling back would be a lie.
    ///
    /// Returns the resolved target AND the EFFECTIVE port: with `relaunch` off a
    /// closed port still REFUSES (`cdpPortClosed`, unchanged); with `relaunch` on it
    /// launches a NEW, ISOLATED instance and returns its OS-chosen port — so the
    /// page session connects to the freshly-launched instance, never the user's
    /// real profile.
    @MainActor
    static func resolveForSelectorVerb(browser: String, lens: WebLens, port: Int,
                                       relaunch: Bool = false)
        async throws -> (target: Target, port: Int) {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        if lens == .ax { throw GhostHandsError.selectorNeedsCDP }
        let target = try Target.resolve(browser)
        // Consent-gated: a closed port refuses unless --relaunch was given, in which
        // case an isolated instance is launched and its chosen port is used.
        let (effectivePort, _) = try await resolveCDPPort(
            target: target, requestedPort: port, relaunch: relaunch)
        return (target, effectivePort)
    }

    /// Surface a page-side JS throw as a transport error rather than flattening it
    /// into a silent nil/empty value. A `Runtime.evaluate` whose in-page expression
    /// THREW returns a reply carrying `exceptionDetails` (and no usable `value`); a
    /// caller that only reads `value` would mistake a genuinely broken page for a
    /// clean no-effect. We REFUSE (`cdpTransport`) so a thrown probe is honestly
    /// distinguished from an honest empty result.
    static func throwIfEvaluateException(_ reply: [String: Any]) throws {
        guard let details = reply["exceptionDetails"] as? [String: Any] else { return }
        // The human-readable text lives in `exception.description` (a thrown Error)
        // or the top-level `text` ("Uncaught"); fall back to a generic note.
        let exception = details["exception"] as? [String: Any]
        let message = (exception?["description"] as? String)
            ?? (details["text"] as? String)
            ?? "page-side JS exception"
        throw GhostHandsError.cdpTransport(reason: "evaluate threw in page: \(message)")
    }

    /// Evaluate an expression that returns a JS OBJECT by value and unwrap it to a
    /// `[String: Any]`. Honest empty `[:]` when the page returned a non-object —
    /// the pure deciders treat an empty object as `notFound`, never a crash. A
    /// page-side THROW is surfaced as `cdpTransport` (a broken page is not a clean
    /// "not found").
    @MainActor
    static func evaluateObject(_ session: CDPSession, _ expression: String)
        async throws -> [String: Any] {
        let reply = try await session.call("Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
        ])
        try throwIfEvaluateException(reply)
        guard let resultObj = reply["result"] as? [String: Any],
              let value = resultObj["value"] as? [String: Any] else { return [:] }
        return value
    }

    /// Read `document.location.href` off the page, or nil when it can't be read
    /// (a non-string result) — so a verdict over a nil before/after is honestly
    /// dispatched-unverified, never a fabricated URL. A page-side THROW is surfaced
    /// as `cdpTransport` rather than masquerading as an unreadable URL.
    @MainActor
    static func readLocationHref(_ session: CDPSession) async throws -> String? {
        let reply = try await session.call("Runtime.evaluate", params: [
            "expression": "document.location.href",
            "returnByValue": true,
        ])
        try throwIfEvaluateException(reply)
        guard let resultObj = reply["result"] as? [String: Any] else { return nil }
        return resultObj["value"] as? String
    }

    /// Dispatch a TRUSTED left click (mousePressed then mouseReleased, clickCount 1)
    /// at a viewport point via `Input.dispatchMouseEvent` — a real input event the
    /// page sees as user-initiated, not a synthetic `el.click()`.
    @MainActor
    static func dispatchTrustedClick(_ session: CDPSession, at p: CGPoint) async throws {
        let common: [String: Any] = [
            "x": Double(p.x), "y": Double(p.y),
            "button": "left", "clickCount": 1,
        ]
        var press = common; press["type"] = "mousePressed"
        var release = common; release["type"] = "mouseReleased"
        _ = try await session.call("Input.dispatchMouseEvent", params: press)
        _ = try await session.call("Input.dispatchMouseEvent", params: release)
    }

    /// Read the href AFTER a click and turn it into a verdict, tolerant of the
    /// navigation race: when a click triggers a REAL navigation, the page's JS
    /// execution context is torn down, so the immediate `document.location.href`
    /// read can land on a dead context and throw `cdpTransport`. That is NOT a
    /// failure — a destroyed context is itself evidence the page navigated. We
    /// settle briefly and retry once (the new context usually answers with the new
    /// URL → a clean VERIFIED with the landed href); if the read STILL throws
    /// transport, we honor the context teardown as VERIFIED-by-navigation rather
    /// than under-claiming a real success as an error. A non-transport error (or a
    /// clean read on either attempt) flows through `clickVerdict` unchanged.
    @MainActor
    static func postClickVerdict(_ session: CDPSession, hrefBefore: String?)
        async throws -> WebActuate.Verdict {
        do {
            let after = try await readLocationHref(session)
            return WebActuate.clickVerdict(hrefBefore: hrefBefore, hrefAfter: after)
        } catch let error as GhostHandsError {
            guard case .cdpTransport = error else { throw error }
            // The execution context was likely destroyed by a navigation. Settle
            // and try once more — the new page's context may now answer.
            try? await Task.sleep(for: .milliseconds(300))
            if let after = try? await readLocationHref(session) {
                return WebActuate.clickVerdict(hrefBefore: hrefBefore, hrefAfter: after)
            }
            // Still no usable read: the torn-down context IS the navigation evidence.
            let from = hrefBefore.map { $0.debugDescription } ?? "the page"
            return .verified(evidence:
                "navigated away from \(from) (page context destroyed by navigation)")
        }
    }

    /// Focus the selector's element, set its `value`, fire `input`+`change`, and
    /// return the value READ BACK off the same element (the verification spine).
    /// Returns nil when the readback isn't a string (the element vanished / has no
    /// `.value`) — honest dispatched-unverified, never a fabricated success. A
    /// page-side THROW (e.g. a `value` setter on a custom element that raises) is
    /// surfaced as `cdpTransport` rather than masquerading as an unreadable value.
    @MainActor
    static func focusSetAndReadBack(_ session: CDPSession, selector: String,
                                    text: String) async throws -> String? {
        let selJSON = WebActuate.jsonStringLiteral(selector)
        let textJSON = WebActuate.jsonStringLiteral(text)
        let expression = """
        (() => {
          const el = document.querySelector(\(selJSON));
          if (!el) return null;
          el.focus();
          el.value = \(textJSON);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return (typeof el.value === 'string') ? el.value : null;
        })()
        """
        let reply = try await session.call("Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
        ])
        try throwIfEvaluateException(reply)
        guard let resultObj = reply["result"] as? [String: Any] else { return nil }
        return resultObj["value"] as? String
    }
}

// MARK: - CDP-only DOM read verbs (web html / web eval) — Slice 3

extension GhostHands {
    /// A `web html` result handed to the CLI: the browser name, the selector read,
    /// the SHAPED (pure) result, and the served port (for the footer).
    public struct WebHtmlResult: Sendable {
        public let app: String
        public let selector: String
        public let shaped: WebHtml.Shaped
        public let port: Int
    }

    /// A `web eval` result handed to the CLI: the browser name, the (already
    /// stringified) value the page returned, and the served port. A page-side THROW
    /// never reaches here — it is surfaced as a `cdpTransport` refuse upstream.
    public struct WebEvalResult: Sendable {
        public let app: String
        public let value: String
        public let port: Int
    }

    /// `web html <selector>` over CDP. Resolve the first debuggable page target,
    /// `Runtime.evaluate` the html probe, and shape the result PURELY.
    ///
    ///   not found → throw `selectorNotFound` (from the pure shaper)
    ///   --ax      → throw `selectorNeedsCDP` (the selector verbs REQUIRE CDP)
    ///   else      → the shaped { tag, outerHTML, attrs, computed } for the CLI to
    ///               render in clear sections. HONEST: reports exactly what the DOM
    ///               exposed — never a fabricated attribute or style.
    @MainActor
    public static func webHtml(selector: String, browser: String, lens: WebLens,
                               debugPort: Int = 9222, relaunch: Bool = false)
        async throws -> WebHtmlResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        // Resolve an `@eN` ref to its `data-gh-ref` selector (CSS passes through).
        let resolved = WebRef.resolve(selector)
        let probe = try await evaluateObject(
            session, WebHtml.htmlProbeExpression(selector: resolved.selector))
        // A ref that matches nothing = the stamped element moved → stale refuse
        // (distinct from the shaper's `selectorNotFound` for a raw CSS selector).
        if resolved.isRef, !WebActuate.boolValue(probe["found"]) {
            throw GhostHandsError.staleRef(ref: selector)
        }
        // The pure shaper raises `selectorNotFound` on a `found:false` probe. The
        // ORIGINAL `selector` (the `@e5` the user typed) is reported, not the
        // resolved attribute selector.
        let shaped = try WebHtml.shape(probe, selector: selector, app: target.name)
        return WebHtmlResult(app: target.name, selector: selector,
                             shaped: shaped, port: port)
    }

    /// `web eval <js>` over CDP. Resolve the first debuggable page target,
    /// `Runtime.evaluate` the given JS (returnByValue + awaitPromise), and classify
    /// the reply PURELY.
    ///
    ///   --ax            → throw `selectorNeedsCDP` (CDP-only power tool)
    ///   page threw      → throw `cdpTransport(reason:)` carrying the exception text
    ///                     — surface the error, NEVER a fake empty success
    ///   else            → the returned value, stringified for printing.
    @MainActor
    public static func webEval(js: String, browser: String, lens: WebLens,
                               debugPort: Int = 9222, relaunch: Bool = false)
        async throws -> WebEvalResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        // Evaluate the caller's expression directly (the WHOLE point of `web eval`
        // is the raw expression — it is the verb's input, never trusted as our code
        // beyond what the user typed). We DON'T go through `evaluateObject` because
        // the result may be ANY type (string/number/array), not just an object.
        let reply = try await session.call("Runtime.evaluate", params: [
            "expression": js,
            "returnByValue": true,
            "awaitPromise": true,
        ])
        switch WebEval.classify(reply) {
        case let .threw(message):
            throw GhostHandsError.cdpTransport(reason: message)
        case let .value(value):
            return WebEvalResult(app: target.name, value: value, port: port)
        }
    }
}
