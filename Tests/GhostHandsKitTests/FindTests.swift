import XCTest
@testable import GhostHandsKit

/// Hermetic — the pure find rendering/dedup over FABRICATED facts. `find` is a
/// PRESENCE probe: it must see static text (not actionable-only), dedup the
/// duplicate-render quirk, and report first + (+N more) for multiple hits.
final class FindTests: XCTestCase {
    private func f(_ role: String, title: String? = nil, value: String? = nil,
                   id: String? = nil, enabled: Bool? = nil) -> ElementFacts {
        ElementFacts(role: role, title: title, identifier: id, value: value, enabled: enabled)
    }

    func testFindSeesStaticText() {
        // The whole point: a static label matches (click's resolver would drop it).
        let label = f("AXStaticText", value: "789")
        XCTAssertTrue(NameMatch.matches(label, query: "789"))
    }

    func testDedupCollapsesDuplicateRender() {
        let hits = [f("AXButton", title: "7"), f("AXButton", title: "7")]
        XCTAssertEqual(FindResult.dedup(hits).count, 1)
    }

    func testDedupKeepsDistinctControls() {
        let hits = [f("AXButton", title: "Save"), f("AXMenuButton", title: "Save")]
        XCTAssertEqual(FindResult.dedup(hits).count, 2)
    }

    func testReportNilWhenEmpty() {
        XCTAssertNil(FindResult.report([]))
    }

    func testReportSingleHasNoMoreSuffix() {
        let r = FindResult.report([f("AXButton", title: "7")])
        XCTAssertNotNil(r)
        XCTAssertFalse(r!.contains("more"))
        XCTAssertTrue(r!.contains("AXButton"))
        XCTAssertTrue(r!.contains("\"7\""))
    }

    func testReportMultipleHasMoreSuffix() {
        let r = FindResult.report([
            f("AXStaticText", value: "7"),
            f("AXButton", title: "7"),
            f("AXButton", title: "7", id: "key7"),
        ])
        XCTAssertEqual(r, FindResult.line(f("AXStaticText", value: "7")) + " (+2 more)")
    }

    func testLineShowsRoleSoStaticVsButtonVisible() {
        XCTAssertTrue(FindResult.line(f("AXStaticText", value: "7")).hasPrefix("AXStaticText"))
        XCTAssertTrue(FindResult.line(f("AXButton", title: "7")).hasPrefix("AXButton"))
    }

    func testLineFlagsDisabled() {
        XCTAssertTrue(FindResult.line(f("AXButton", title: "Go", enabled: false)).contains("(disabled)"))
    }
}
