import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE `extract` tier over FABRICATED tabular AX trees. No live
/// app is driven. Verifies the shaper (header present/absent, AXCell rows, leaf-
/// cell fallback, ragged rows, blank cells, AXList items, AXOutline nesting,
/// empty-but-present table) and the renderer (TSV rows, header first, honest
/// empty), pinning the honesty contract: ONLY AX-exposed values, a blank cell is
/// empty (never guessed), an empty table is honest-empty output (not a refuse).
final class ExtractTests: XCTestCase {
    // MARK: - fabrication helpers

    private func n(_ role: String, title: String? = nil, value: String? = nil,
                   id: String? = nil, desc: String? = nil,
                   children: [TableNode] = []) -> TableNode {
        TableNode(facts: ElementFacts(role: role, title: title, identifier: id,
                                      value: value, descriptionText: desc),
                  children: children)
    }

    /// A realistic AXTable: two AXColumn headers, then two AXRow rows of AXCells.
    private func tableWithHeader() -> TableNode {
        n("AXTable", children: [
            n("AXColumn", title: "Name"),
            n("AXColumn", title: "Size"),
            n("AXRow", children: [
                n("AXCell", value: "report.pdf"),
                n("AXCell", value: "2 MB"),
            ]),
            n("AXRow", children: [
                n("AXCell", value: "notes.txt"),
                n("AXCell", value: "4 KB"),
            ]),
        ])
    }

    // MARK: - header extraction

    func testHeaderExtractedFromColumns() {
        let model = TableShaper.shape(tableWithHeader())
        XCTAssertEqual(model.header, ["Name", "Size"])
        XCTAssertEqual(model.rows.count, 2)
    }

    func testNoColumnsMeansNoHeader() {
        // A table with rows but NO AXColumn children → no header, never fabricated.
        let table = n("AXTable", children: [
            n("AXRow", children: [n("AXCell", value: "a"), n("AXCell", value: "b")]),
        ])
        let model = TableShaper.shape(table)
        XCTAssertNil(model.header)
        XCTAssertEqual(model.rows, [["a", "b"]])
    }

    func testColumnsWithNoTitlesMeansNoHeader() {
        // AXColumns present but none carries a readable title → honest no header
        // (we don't emit a row of blanks pretending to be a header).
        let table = n("AXTable", children: [
            n("AXColumn"),
            n("AXColumn"),
            n("AXRow", children: [n("AXCell", value: "x"), n("AXCell", value: "y")]),
        ])
        let model = TableShaper.shape(table)
        XCTAssertNil(model.header)
    }

    func testPartiallyTitledColumnsKeepAlignment() {
        // Some columns titled, some not → the untitled ones are blank so the
        // header still aligns to the cell columns (never dropped to a short header).
        let table = n("AXTable", children: [
            n("AXColumn", title: "Name"),
            n("AXColumn"),                       // untitled → blank header cell
            n("AXColumn", title: "Date"),
            n("AXRow", children: [
                n("AXCell", value: "a"), n("AXCell", value: "b"), n("AXCell", value: "c"),
            ]),
        ])
        let model = TableShaper.shape(table)
        XCTAssertEqual(model.header, ["Name", "", "Date"])
    }

    func testColumnHeaderFallsBackToDescriptionThenIdentifier() {
        let table = n("AXTable", children: [
            n("AXColumn", desc: "Described"),
            n("AXColumn", id: "col_id"),
            n("AXRow", children: [n("AXCell", value: "a"), n("AXCell", value: "b")]),
        ])
        let model = TableShaper.shape(table)
        XCTAssertEqual(model.header, ["Described", "col_id"])
    }

    // MARK: - cells: value precedence + honest blanks

    func testCellValuePrecedence() {
        // value wins; then title; then identifier; then description.
        XCTAssertEqual(TableShaper.cellString(
            ElementFacts(role: "AXCell", title: "T", value: "V")), "V")
        XCTAssertEqual(TableShaper.cellString(
            ElementFacts(role: "AXCell", title: "T")), "T")
        XCTAssertEqual(TableShaper.cellString(
            ElementFacts(role: "AXCell", identifier: "ID")), "ID")
        XCTAssertEqual(TableShaper.cellString(
            ElementFacts(role: "AXCell", descriptionText: "D")), "D")
    }

    func testUnreadableCellIsBlankNeverGuessed() {
        // A cell with NO readable text → "" (blank), never the role or a guess.
        XCTAssertEqual(TableShaper.cellString(ElementFacts(role: "AXCell")), "")
        let table = n("AXTable", children: [
            n("AXRow", children: [
                n("AXCell", value: "filled"),
                n("AXCell"),                     // empty → blank, NOT "AXCell"
            ]),
        ])
        let model = TableShaper.shape(table)
        XCTAssertEqual(model.rows, [["filled", ""]])
        XCTAssertFalse(TableRender.render(model).contains("AXCell"))
    }

    func testEmptyValueStringIsBlankNotMisread() {
        // An explicit empty-string value is treated as blank (honest), not kept
        // as a zero-length field that masquerades as content.
        let cell = ElementFacts(role: "AXCell", value: "")
        XCTAssertEqual(TableShaper.cellString(cell), "")
    }

    // MARK: - leaf-cell fallback (no AXCell wrapper)

    func testRowWithoutAXCellsUsesLeafChildren() {
        // Some apps expose row values on direct leaf children (no AXCell wrapper).
        let table = n("AXTable", children: [
            n("AXRow", children: [
                n("AXStaticText", value: "leaf1"),
                n("AXStaticText", value: "leaf2"),
            ]),
        ])
        let model = TableShaper.shape(table)
        XCTAssertEqual(model.rows, [["leaf1", "leaf2"]])
    }

    func testRowWithNoChildrenIsOneBlankCell() {
        // An AXRow with no children still COUNTS as a row (it exists) — one blank
        // cell, honest about the empty row, never dropped.
        let table = n("AXTable", children: [
            n("AXRow"),
            n("AXRow", children: [n("AXCell", value: "x")]),
        ])
        let model = TableShaper.shape(table)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows[0], [""])
        XCTAssertEqual(model.rows[1], ["x"])
    }

    // MARK: - ragged rows preserved

    func testRaggedRowsKeptAsExposed() {
        // Rows of differing widths are emitted verbatim — we never pad to a
        // rectangle or truncate; the renderer keeps each row's own cell count.
        let table = n("AXTable", children: [
            n("AXColumn", title: "A"),
            n("AXColumn", title: "B"),
            n("AXRow", children: [n("AXCell", value: "1"), n("AXCell", value: "2")]),
            n("AXRow", children: [n("AXCell", value: "solo")]),     // narrow
            n("AXRow", children: [
                n("AXCell", value: "x"), n("AXCell", value: "y"), n("AXCell", value: "z"),
            ]),                                                     // wide
        ])
        let model = TableShaper.shape(table)
        XCTAssertEqual(model.rows, [["1", "2"], ["solo"], ["x", "y", "z"]])
    }

    // MARK: - structural walk-through

    func testStructuralGroupBetweenTableAndRowsWalkedThrough() {
        // An AXGroup wrapping the rows is walked through (not emitted), so the
        // rows still surface — the container's structure varies across apps.
        let table = n("AXTable", children: [
            n("AXColumn", title: "Col"),
            n("AXGroup", children: [
                n("AXRow", children: [n("AXCell", value: "r1")]),
                n("AXRow", children: [n("AXCell", value: "r2")]),
            ]),
        ])
        let model = TableShaper.shape(table)
        XCTAssertEqual(model.rows, [["r1"], ["r2"]])
    }

    // MARK: - AXOutline nesting (disclosed parent → child rows)

    func testOutlineNestedRowsAllCollected() {
        // An AXOutline discloses child rows nested INSIDE a parent row. All rows
        // (parent then children, pre-order) are collected.
        let outline = n("AXOutline", children: [
            n("AXColumn", title: "Item"),
            n("AXRow", children: [
                n("AXCell", value: "Parent"),
                n("AXRow", children: [n("AXCell", value: "Child A")]),
                n("AXRow", children: [n("AXCell", value: "Child B")]),
            ]),
        ])
        let model = TableShaper.shape(outline)
        // Parent's own cells: its first AXCell is "Parent"; its nested AXRows are
        // collected as their own rows. (cells() reads the row's AXCell children.)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows[0], ["Parent"])
        XCTAssertEqual(model.rows[1], ["Child A"])
        XCTAssertEqual(model.rows[2], ["Child B"])
    }

    func testOutlineParentRowWithoutAXCellDoesNotDuplicateNestedRows() {
        // A disclosed parent AXRow with NO leading AXCell of its own, only nested
        // AXRow children: the nested rows are collected as their OWN rows — they
        // must NOT also be mis-read as the parent's leaf cells (which would emit a
        // duplicate, near-blank parent row). The parent here exposes no real leaf
        // cell, so its own row is a single honest blank.
        let outline = n("AXOutline", children: [
            n("AXRow", children: [
                n("AXRow", children: [n("AXCell", value: "Child A")]),
                n("AXRow", children: [n("AXCell", value: "Child B")]),
            ]),
        ])
        let model = TableShaper.shape(outline)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows[0], [""])              // parent: no real cell → one blank
        XCTAssertEqual(model.rows[1], ["Child A"])       // nested rows surface ONCE, as rows
        XCTAssertEqual(model.rows[2], ["Child B"])
        // The nested-row values are NOT duplicated into the parent's cells.
        XCTAssertFalse(model.rows[0].contains("Child A"))
        XCTAssertFalse(model.rows[0].contains("Child B"))
    }

    // MARK: - AXList items (flat, one value per line, no header)

    func testListItemsOneValuePerLine() {
        let list = n("AXList", children: [
            n("AXStaticText", value: "alpha"),
            n("AXStaticText", value: "beta"),
            n("AXStaticText", value: "gamma"),
        ])
        let model = TableShaper.shape(list)
        XCTAssertNil(model.header)                       // a list has no header
        XCTAssertEqual(model.rows, [["alpha"], ["beta"], ["gamma"]])
    }

    func testListItemUnreadableIsBlank() {
        let list = n("AXList", children: [
            n("AXStaticText", value: "ok"),
            n("AXStaticText"),                           // no readable value → blank
        ])
        let model = TableShaper.shape(list)
        XCTAssertEqual(model.rows, [["ok"], [""]])
    }

    // MARK: - empty-but-present table → honest empty (NOT a refuse)

    func testEmptyTableIsZeroRowsNotRefuse() {
        // A real AXTable that exposes NO rows shapes to 0 rows — the renderer's
        // honest empty. The REFUSE (noTabularData) is for a MISSING table, which
        // is the resolver's job, not the shaper's.
        let table = n("AXTable", children: [
            n("AXColumn", title: "Only a header"),
        ])
        let model = TableShaper.shape(table)
        XCTAssertEqual(model.rows.count, 0)
        XCTAssertEqual(model.header, ["Only a header"])
        // A header but no rows renders just the header line (honest, not empty).
        XCTAssertEqual(TableRender.render(model), "Only a header")
    }

    func testTrulyEmptyTableRendersEmptyString() {
        // No columns, no rows → an honest empty rendering ("" — never a placeholder).
        let table = n("AXTable")
        let model = TableShaper.shape(table)
        XCTAssertNil(model.header)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(TableRender.render(model), "")
        XCTAssertEqual(TableRender.rowCount(model), 0)
    }

    func testEmptyListRendersEmptyString() {
        let model = TableShaper.shape(n("AXList"))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(TableRender.render(model), "")
    }

    // MARK: - render shape (TSV: tabs between cells, newlines between rows)

    func testRenderTSVWithHeaderFirst() {
        let model = TableShaper.shape(tableWithHeader())
        let rendered = TableRender.render(model)
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertEqual(lines.count, 3)                   // header + 2 rows
        XCTAssertEqual(lines[0], "Name\tSize")           // header first, tab-joined
        XCTAssertEqual(lines[1], "report.pdf\t2 MB")
        XCTAssertEqual(lines[2], "notes.txt\t4 KB")
    }

    func testRenderLineJoinsWithTabs() {
        XCTAssertEqual(TableRender.line(["a", "b", "c"]), "a\tb\tc")
    }

    func testRenderBlankCellIsEmptyField() {
        // A blank cell renders as an empty TSV field (tab preserved), so column
        // alignment survives a missing value — honest, never a fabricated dash.
        XCTAssertEqual(TableRender.line(["a", "", "c"]), "a\t\tc")
    }

    func testRowCountExcludesHeader() {
        let model = TableShaper.shape(tableWithHeader())
        XCTAssertEqual(TableRender.rowCount(model), 2)   // 2 data rows, header not counted
    }

    // MARK: - determinism (pure function of the tree)

    func testShapeIsDeterministic() {
        let table = tableWithHeader()
        XCTAssertEqual(TableShaper.shape(table), TableShaper.shape(table))
        XCTAssertEqual(TableRender.render(TableShaper.shape(table)),
                       TableRender.render(TableShaper.shape(table)))
    }
}
