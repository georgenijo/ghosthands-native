import XCTest
@testable import GhostHandsKit

/// Hermetic — the pure snapshot formatter over a FABRICATED node forest (no AX
/// walk). Verifies indentation, the role/name/value line shape, the disabled
/// flag, the count, and JSON escaping. HONEST: an empty forest renders empty.
final class SnapshotRenderTests: XCTestCase {
    private func node(_ role: String, title: String? = nil, value: String? = nil,
                      id: String? = nil, enabled: Bool? = nil, depth: Int,
                      children: [SnapshotNode] = []) -> SnapshotNode {
        SnapshotNode(facts: ElementFacts(role: role, title: title, identifier: id,
                                         value: value, enabled: enabled),
                     depth: depth, children: children)
    }

    func testEmptyForestRendersEmpty() {
        XCTAssertEqual(SnapshotRender.ax([]), "")
        XCTAssertEqual(SnapshotRender.count([]), 0)
    }

    func testLineIndentsByDepth() {
        let root = node("AXWindow", title: "Calc", depth: 0)
        let child = node("AXButton", title: "7", depth: 1)
        XCTAssertEqual(SnapshotRender.line(root), "AXWindow \"Calc\"")
        XCTAssertEqual(SnapshotRender.line(child), "  AXButton \"7\"")
    }

    func testValueShownWhenDistinctFromName() {
        // A display: title nil, value present → value appears once.
        let display = node("AXStaticText", value: "789", depth: 2)
        let line = SnapshotRender.line(display)
        // displayName falls back to value, so it shows as the quoted name; the
        // value= suffix is suppressed to avoid duplication.
        XCTAssertTrue(line.contains("789"))
        XCTAssertFalse(line.contains("value=\"789\" value="))
    }

    func testValueSuffixWhenNameAndValueDiffer() {
        let f = node("AXTextField", title: "Amount", value: "42", depth: 0)
        let line = SnapshotRender.line(f)
        XCTAssertTrue(line.contains("\"Amount\""))
        XCTAssertTrue(line.contains("value=\"42\""))
    }

    func testDisabledFlagged() {
        let f = node("AXButton", title: "Go", enabled: false, depth: 0)
        XCTAssertTrue(SnapshotRender.line(f).contains("(disabled)"))
    }

    func testTreeIsPreOrder() {
        let forest = [node("AXWindow", title: "W", depth: 0, children: [
            node("AXButton", title: "A", depth: 1),
            node("AXButton", title: "B", depth: 1, children: [
                node("AXStaticText", value: "leaf", depth: 2),
            ]),
        ])]
        let lines = SnapshotRender.ax(forest).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("\"W\""))
        XCTAssertTrue(lines[1].contains("\"A\""))
        XCTAssertTrue(lines[2].contains("\"B\""))
        XCTAssertTrue(lines[3].contains("leaf"))
        XCTAssertTrue(lines[3].hasPrefix("    "))   // depth 2 → 4 spaces
    }

    func testCountSumsWholeForest() {
        let forest = [node("AXWindow", depth: 0, children: [
            node("AXButton", title: "A", depth: 1),
            node("AXButton", title: "B", depth: 1),
        ])]
        XCTAssertEqual(SnapshotRender.count(forest), 3)
    }

    func testDisplayNameFallbackToCleanedRole() {
        // Nothing nameable → cleaned role (AX prefix dropped).
        let f = ElementFacts(role: "AXGroup")
        XCTAssertEqual(SnapshotRender.displayName(f), "Group")
    }

    func testJSONEscapesAndIncludesFields() {
        let forest = [node("AXStaticText", value: "a\"b\nc", depth: 0)]
        let json = SnapshotRender.json(forest)
        XCTAssertTrue(json.contains("\"role\": \"AXStaticText\""))
        XCTAssertTrue(json.contains("\\\"b"))   // escaped quote
        XCTAssertTrue(json.contains("\\n"))      // escaped newline
        XCTAssertTrue(json.contains("\"depth\": 0"))
        XCTAssertTrue(json.contains("\"supportsPress\": false"))
    }

    func testJSONNullForMissingFields() {
        let forest = [node("AXButton", depth: 0)]
        let json = SnapshotRender.json(forest)
        XCTAssertTrue(json.contains("\"title\": null"))
        XCTAssertTrue(json.contains("\"enabled\": null"))
    }
}
