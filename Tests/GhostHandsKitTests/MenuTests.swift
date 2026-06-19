import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE menu logic: path parsing and one-level title matching, plus
/// the refuse-error descriptions. The AX walk (open menu → descend → AXPress) is
/// live-only (a real app menu bar), never driven in a unit test.
final class MenuTests: XCTestCase {

    // MARK: - MenuPath.parse

    func testParseSplitsTrimsAndDropsEmpty() {
        XCTAssertEqual(MenuPath.parse("File > Open Recent > ~/Documents/code/murmur-app"),
                       ["File", "Open Recent", "~/Documents/code/murmur-app"])
        XCTAssertEqual(MenuPath.parse("  File  >   Edit "), ["File", "Edit"])
        XCTAssertEqual(MenuPath.parse(">File>"), ["File"])
        XCTAssertEqual(MenuPath.parse("File"), ["File"])
        XCTAssertEqual(MenuPath.parse(""), [])
        XCTAssertEqual(MenuPath.parse("   "), [])
    }

    /// A path segment keeps its slashes, tilde, and spaces — only `>` splits.
    func testParsePreservesPathLikeSegment() {
        XCTAssertEqual(MenuPath.parse("File > ~/a b/c-d"), ["File", "~/a b/c-d"])
    }

    // MARK: - MenuMatch.choose

    func testChooseExactWins() {
        XCTAssertEqual(MenuMatch.choose(["File", "Edit", "View"], query: "Edit"), .one(1))
    }

    func testChooseExactIsCaseInsensitive() {
        XCTAssertEqual(MenuMatch.choose(["File", "Edit"], query: "file"), .one(0))
    }

    func testChooseSubstringUnique() {
        XCTAssertEqual(MenuMatch.choose(["Open…", "Open Recent"], query: "Open Rec"), .one(1))
    }

    /// The ellipsis menus append is handled by substring — "Open Folder" matches
    /// "Open Folder…".
    func testChooseSubstringMatchesEllipsis() {
        XCTAssertEqual(MenuMatch.choose(["Open Folder…", "Open Workspace…"],
                                        query: "Open Folder"), .one(0))
    }

    /// EXACT beats substring: "Open" resolves to the exact "Open" item even though
    /// "Open Recent" also contains the substring — no false ambiguity.
    func testChooseExactBeatsSubstring() {
        XCTAssertEqual(MenuMatch.choose(["Open", "Open Recent"], query: "Open"), .one(0))
    }

    /// >1 substring hit with NO exact match is AMBIGUOUS — refuse, never guess.
    func testChooseAmbiguousSubstring() {
        XCTAssertEqual(MenuMatch.choose(["Save As…", "Save All"], query: "Save"),
                       .ambiguous([0, 1]))
    }

    func testChooseNone() {
        XCTAssertEqual(MenuMatch.choose(["File", "Edit"], query: "View"), .none)
    }

    /// Empty titles (separators / blanks in the menu) never match a real query.
    func testChooseSkipsEmptyTitles() {
        XCTAssertEqual(MenuMatch.choose(["", "File", ""], query: "File"), .one(1))
    }

    // MARK: - refuse-error descriptions

    func testMenuBarUnavailableDescription() {
        let e = GhostHandsError.menuBarUnavailable(app: "Cursor")
        XCTAssertTrue(e.description.contains("Cursor"))
        XCTAssertTrue(e.description.lowercased().contains("menu bar"))
    }

    func testMenuItemNotFoundListsAvailable() {
        let e = GhostHandsError.menuItemNotFound(
            segment: "Frobnicate", app: "Cursor", available: ["File", "Edit", "View"])
        XCTAssertTrue(e.description.contains("Frobnicate"))
        XCTAssertTrue(e.description.contains("File"))
        XCTAssertTrue(e.description.lowercased().contains("refus"))
    }

    func testNotASubmenuDescription() {
        let e = GhostHandsError.notASubmenu(segment: "Save", app: "Cursor")
        XCTAssertTrue(e.description.contains("Save"))
        XCTAssertTrue(e.description.lowercased().contains("submenu"))
    }
}
