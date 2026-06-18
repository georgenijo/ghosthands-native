import AppKit
import ApplicationServices
import AXorcist
import Foundation

// GhostHands EXTRACT tier — the "collect anything" native read, AX only, no model.
//
// `extract <app> [--in <name>]` pulls STRUCTURED tabular data off a macOS app's
// accessibility tree: the rows (and, where the table advertises them, the column
// headers) of an `AXTable` / `AXOutline` / `AXList`, rendered as clean TSV-like
// text (header first when present). It is the read counterpart to `snapshot`
// (which dumps the raw tree) — `extract` shapes ONE tabular container into the
// rows a brain (or a human) actually wants to read or copy.
//
// Resolution:
//   --in <name>  → a NAMED AXTable / AXOutline / AXList (bounded search; REFUSE
//                  on an ambiguous match, like the other named verbs).
//   else         → the FIRST / primary tabular container in the frontmost window.
//   none found   → REFUSE (`noTabularData`).
//
// Honesty contract (same as the rest of the kit):
//   - We emit ONLY the cell values AX actually exposes. A cell with no readable
//     value is BLANK, never guessed.
//   - An EMPTY table (a real container that exposes zero AXRow children) is an
//     honest EMPTY output (0 rows), NOT a refuse.
//   - A MISSING table (no AXTable/AXOutline/AXList found at all) is a REFUSE
//     (`noTabularData`), never a fabricated row.
//
// PURITY: the AX-touching step is a single bounded walk that produces a pure
// `TableNode` tree (`ElementFacts` + ordered children). Everything below — header
// extraction, row/cell shaping, and rendering — is a PURE function over that
// fabricated-or-real tree, so it is hermetically unit-tested with no live app.

// MARK: - Pure node model

/// One node of a raw tabular AX subtree: pure facts + ordered children. Mirrors
/// `WebNode` (no baked-in depth) — the shaper reads the table's OWN structure
/// (rows → cells), not a global tree depth, so depth is not part of the model.
public struct TableNode: Sendable, Equatable {
    public var facts: ElementFacts
    public var children: [TableNode]

    public init(facts: ElementFacts, children: [TableNode] = []) {
        self.facts = facts
        self.children = children
    }
}

// MARK: - Pure table model + shaper

/// The shaped, AX-free result of reading a tabular container: an OPTIONAL header
/// (the column titles, present only when the table advertises AXColumns with
/// header titles) and the rows (each a list of cell strings). A pure value type
/// so the shaper + renderer are unit-tested over fabricated facts.
///
/// HONEST: a cell AX exposes no readable value for is the empty string (blank),
/// never a guess. `rows` is empty for an empty-but-present table (0 rows), which
/// the renderer turns into honest empty output, NOT a refuse.
public struct TableModel: Sendable, Equatable {
    /// Column header titles, when the table advertises them. nil ⇒ no header was
    /// exposed (an AXList, or an AXTable/AXOutline with no header titles) — the
    /// renderer then emits rows only, never a fabricated header.
    public var header: [String]?
    /// One entry per AXRow (or per AXList item), each its ordered cell strings.
    public var rows: [[String]]

    public init(header: [String]? = nil, rows: [[String]]) {
        self.header = header
        self.rows = rows
    }
}

/// Pure shaping of a `TableNode` container into a `TableModel`. All AX-free — the
/// input is a fabricated-or-real node tree, so the shaper is hermetically tested.
public enum TableShaper {
    /// The container roles `extract` reads. AXTable / AXOutline are row+cell
    /// grids; AXList is a flat list of items (one value per line).
    public static let tabularRoles: Set<String> = ["AXTable", "AXOutline", "AXList"]

    /// Row / item / header / cell / column roles inside a tabular container.
    public static let rowRoles: Set<String> = ["AXRow"]
    public static let cellRoles: Set<String> = ["AXCell"]
    public static let columnRoles: Set<String> = ["AXColumn"]

    /// A readable string for one CELL (or a leaf item) — its value, else title,
    /// else identifier, else description text. Deliberately does NOT fall through
    /// to the role: a cell with no real content is BLANK ("") so the row keeps its
    /// shape (column alignment) without a fabricated "AXCell" placeholder. HONEST:
    /// AX gave nothing readable ⇒ blank, never guessed.
    public static func cellString(_ f: ElementFacts) -> String {
        for candidate in [f.value, f.title, f.identifier, f.descriptionText] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return ""
    }

    /// A readable HEADER title for one AXColumn — its title, else description,
    /// else identifier, else value. nil ⇒ this column exposes no readable header
    /// title (so the header as a whole may be dropped; see `header(of:)`).
    public static func columnTitle(_ f: ElementFacts) -> String? {
        for candidate in [f.title, f.descriptionText, f.identifier, f.value] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// Extract the column header titles from a container's direct AXColumn
    /// children. Returns nil when the container exposes NO columns, or none of the
    /// exposed columns carries a readable title — an honest "no header", never a
    /// fabricated one. When SOME columns are titled and some are not, the
    /// untitled ones are blank so the header still aligns to the cell columns.
    public static func header(of container: TableNode) -> [String]? {
        let columns = container.children.filter { columnRoles.contains($0.facts.role ?? "") }
        guard !columns.isEmpty else { return nil }
        let titles = columns.map { columnTitle($0.facts) }
        // If not a single column carries a real title, there is no honest header.
        guard titles.contains(where: { $0 != nil }) else { return nil }
        return titles.map { $0 ?? "" }
    }

    /// The cells of one AXRow, in order. A row's cells are its AXCell children;
    /// some apps expose the value directly on the row's leaf children (no AXCell
    /// wrapper). So: prefer AXCell children when present; else fall back to the
    /// row's direct children as leaf cells. Each cell is `cellString` (blank when
    /// AX exposes nothing). An AXRow with NO children is a single blank cell, so
    /// an empty row still counts as a row (honest: the row exists).
    ///
    /// The leaf-cell fallback EXCLUDES nested AXRow children: in an AXOutline a
    /// disclosed parent row holds its child rows as nested AXRows, and those are
    /// collected as their OWN rows by `rows(under:)` — reading them here too would
    /// emit a duplicate, near-blank parent row. Excluding them keeps the parent's
    /// cells honest (its real leaf cells only, or a single blank when it has none).
    public static func cells(of row: TableNode) -> [String] {
        let axCells = row.children.filter { cellRoles.contains($0.facts.role ?? "") }
        let leafChildren = row.children.filter { !rowRoles.contains($0.facts.role ?? "") }
        let cellNodes = axCells.isEmpty ? leafChildren : axCells
        guard !cellNodes.isEmpty else { return [""] }
        return cellNodes.map { cellString($0.facts) }
    }

    /// Find every AXRow under a container (rows can nest in an AXOutline — a
    /// disclosed parent row holds child rows — so we walk, BOUNDED by depth + a
    /// visited-equivalent: `TableNode` is an acyclic value tree, so depth alone
    /// bounds it). Pre-order, so a disclosed outline reads parent-then-children.
    public static func rows(under container: TableNode, maxDepth: Int = 40) -> [TableNode] {
        var out: [TableNode] = []
        func walk(_ node: TableNode, depth: Int) {
            guard depth < maxDepth else { return }
            for child in node.children {
                if rowRoles.contains(child.facts.role ?? "") {
                    out.append(child)
                    // Descend INTO the row for nested (disclosed) child rows, but
                    // not past the depth bound.
                    walk(child, depth: depth + 1)
                } else {
                    // A non-row structural child (e.g. an AXGroup wrapping rows) —
                    // walk through it without emitting it.
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(container, depth: 0)
        return out
    }

    /// The flat ITEMS of an AXList — one value per child item (AXList exposes its
    /// entries as direct children, not AXRow/AXCell). Each item is one cell
    /// string, so the renderer emits one value per line. Honest blank for an item
    /// with no readable value.
    public static func listItems(of container: TableNode) -> [[String]] {
        container.children.map { [cellString($0.facts)] }
    }

    /// Shape a tabular container node into a `TableModel`.
    ///
    /// - An AXList → one value per item (no header, one cell per row).
    /// - An AXTable / AXOutline → optional column header + one row per AXRow, each
    ///   the row's cell strings.
    /// HONEST: an empty container (no rows / no items) shapes to `rows: []` (the
    /// renderer's honest empty), never a fabricated row.
    public static func shape(_ container: TableNode) -> TableModel {
        let role = container.facts.role ?? ""
        if role == "AXList" {
            // A list is a flat column of values — no header.
            return TableModel(header: nil, rows: listItems(of: container))
        }
        // AXTable / AXOutline (and anything else passed here): header + rows.
        let head = header(of: container)
        let rowNodes = rows(under: container)
        let rows = rowNodes.map { cells(of: $0) }
        return TableModel(header: head, rows: rows)
    }
}

// MARK: - Pure render

/// Pure rendering of a `TableModel` into clean TSV-like text — header first when
/// present, then one tab-joined row per line. No AX here, so it is hermetically
/// tested. HONEST: an empty model (0 rows, no header) renders the empty string,
/// never a fabricated placeholder; a blank cell is an empty field, never a guess.
public enum TableRender {
    /// One row joined by tabs. A blank cell is an empty field — the tabs keep the
    /// column positions so a ragged / blank-celled row still aligns to its header.
    public static func line(_ cells: [String]) -> String {
        cells.joined(separator: "\t")
    }

    /// The full TSV-like rendering: the header line first (when present), then one
    /// line per row. Empty model ⇒ "" (honest empty). The header is NOT counted as
    /// a row — it is a separate, optional first line.
    public static func render(_ model: TableModel) -> String {
        var lines: [String] = []
        if let header = model.header { lines.append(line(header)) }
        for row in model.rows { lines.append(line(row)) }
        return lines.joined(separator: "\n")
    }

    /// The honest row count (data rows only, header excluded) for the footer.
    public static func rowCount(_ model: TableModel) -> Int { model.rows.count }
}

// MARK: - AX-touching walk (the only impure step)

/// Builds a raw `TableNode` subtree from a live tabular container `Element`.
/// Mirrors `SnapshotWalker` / `WebWalker`: recurses with raw
/// `children(strict: true)` (a true parent → child tree, not the over-collecting
/// search funnel), BOUNDED by a depth cap + a visited-set — AXorcist's `children`
/// is for SEARCH, not a clean acyclic tree, and a cyclic AX subtree would
/// otherwise overflow the stack (the SIGSEGV the depth bound prevents). The
/// result is a pure tree handed to the pure `TableShaper`.
@MainActor
enum TableWalker {
    static let maxDepth = 60

    /// Walk a tabular container element into a pure `TableNode`.
    static func node(of container: Element) -> TableNode {
        var visited = Set<Element>()
        return build(from: container, depth: 0, visited: &visited)
    }

    private static func build(from element: Element, depth: Int,
                              visited: inout Set<Element>) -> TableNode {
        let facts = Finder.facts(of: element)
        guard depth < maxDepth, !visited.contains(element) else {
            return TableNode(facts: facts)
        }
        visited.insert(element)
        let kids = element.children(strict: true) ?? []
        return TableNode(facts: facts,
                         children: kids.map { build(from: $0, depth: depth + 1, visited: &visited) })
    }
}

// MARK: - Public entry point

extension GhostHands {
    /// An `extract` result handed to the CLI: the resolved app, a human label for
    /// the container read, and the shaped table model.
    public struct ExtractResult: Sendable {
        public let app: String
        /// A human label for the container we read (its title / identifier / role).
        public let container: String
        public let model: TableModel
        public var rowCount: Int { TableRender.rowCount(model) }
    }

    /// `extract <app> [--in <name>]` — read a tabular container into structured
    /// rows. Pure read: no press, no focus steal.
    ///
    /// Honesty contract (nothing here ever hardcodes a row):
    /// - throws `.accessibilityNotTrusted` if AX permission is missing,
    /// - throws `.appNotFound` / `.appAmbiguous` from `Target.resolve`,
    /// - throws `.ambiguousMatch` when `--in <name>` matches >1 distinct container,
    /// - throws `.noTabularData` when NO AXTable/AXOutline/AXList is found,
    /// - otherwise returns an `ExtractResult` whose model carries ONLY the values
    ///   AX exposed (an empty-but-present table ⇒ 0 rows, an honest empty result).
    @MainActor
    public static func extract(appSpec: String, container named: String? = nil,
                               settle: TimeInterval = 0.4) throws -> ExtractResult {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        // Resolve the tabular container. A first attempt; if none is found (a
        // cold/just-bound window can hand back a sparse tree a beat before it
        // fills), settle once and re-resolve on a fresh app element. A genuinely
        // tableless app stays tableless after that single retry → REFUSE.
        var container = try resolveTabularContainer(named: named, target: target)
        if container == nil, settle > 0 {
            Thread.sleep(forTimeInterval: settle)
            let fresh = Target(app: target.app)
            container = try resolveTabularContainer(named: named, target: fresh)
        }
        guard let container else {
            throw GhostHandsError.noTabularData(app: target.name, named: named)
        }

        let label = tabularLabel(container)
        let node = TableWalker.node(of: container)
        let model = TableShaper.shape(node)
        return ExtractResult(app: target.name, container: label, model: model)
    }

    // MARK: - container resolution

    /// Resolve the tabular container to read: a NAMED one (`--in`), else the FIRST
    /// (primary) AXTable / AXOutline / AXList in the frontmost window. nil ⇒ none
    /// found (the caller REFUSES). Throws `.ambiguousMatch` when `--in` matches
    /// more than one DISTINCT container — refuse rather than read an arbitrary one
    /// (like the other named verbs).
    @MainActor
    static func resolveTabularContainer(named: String?, target: Target) throws -> Element? {
        // A named container: match a tabular element by name, role-gated to the
        // tabular roles (a label that merely shares the name is excluded). A
        // substring search can match SEVERAL containers; resolve through
        // `NameMatch` so >1 distinct container is AMBIGUOUS (refuse), never a
        // silent `.first`.
        if let named {
            // Finder.descendants is CYCLE-SAFE (visited-set) — AXorcist's
            // searchElements is not, and a cyclic content tree HANGS it.
            let matches = Finder.descendants(under: target.element) {
                TableShaper.tabularRoles.contains($0.role() ?? "")
            }
            let facts = matches.map { Finder.facts(of: $0) }
            switch NameMatch.resolve(facts, query: named) {
            case let .unique(i): return matches[i]
            case let .ambiguous(labels):
                throw GhostHandsError.ambiguousMatch(name: named, candidates: labels)
            case .none: return nil
            }
        }

        // Auto-pick: the FIRST tabular container in the frontmost window (the
        // primary one). Scope to the frontmost window so we never read an
        // off-screen / background window's table. Prefer AXTable, then AXOutline,
        // then AXList (a grid is "more tabular" than a flat list), and within a
        // role take the first in tree order — a deterministic, honest pick.
        let window = frontmostWindow(of: target) ?? target.element
        let tabular = Finder.descendants(under: window) {
            TableShaper.tabularRoles.contains($0.role() ?? "")
        }
        for role in ["AXTable", "AXOutline", "AXList"] {
            if let first = tabular.first(where: { $0.role() == role }) { return first }
        }
        return nil
    }

    /// A human label for the chosen container — its title / identifier /
    /// role-description, else a role-derived name. Never fabricated.
    @MainActor
    static func tabularLabel(_ container: Element) -> String {
        if let t = container.title(), !t.isEmpty { return t }
        if let id = container.identifier(), !id.isEmpty { return id }
        if let rd = container.roleDescription(), !rd.isEmpty { return rd }
        if let role = container.role(), !role.isEmpty {
            return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        }
        return "table"
    }
}
