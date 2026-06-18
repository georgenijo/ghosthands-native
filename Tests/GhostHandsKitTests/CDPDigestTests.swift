import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE shaping of a `Runtime.evaluate` DOM-digest array into
/// `WebDigest.Entry` values, over a FABRICATED `[[String:Any]]`. No socket, no
/// browser. Verifies tag→AX-role mapping, the drop-empty rule, the bounding box,
/// and the browser-surface routing hint.
final class CDPDigestTests: XCTestCase {
    /// Tags map to AX-ish roles, names/values carry through, and the box becomes
    /// the entry frame so the existing renderer can tag it.
    func testEntriesMapRolesAndBoxes() {
        let rows: [[String: Any]] = [
            ["role": "a", "name": "Sign in", "value": "",
             "x": 10.0, "y": 20.0, "w": 80.0, "h": 24.0],
            ["role": "button", "name": "Submit", "value": "",
             "x": 0.0, "y": 0.0, "w": 50.0, "h": 30.0],
            ["role": "h1", "name": "Welcome", "value": "",
             "x": 0.0, "y": 0.0, "w": 200.0, "h": 40.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.map { $0.facts.role }, ["AXLink", "AXButton", "AXHeading"])
        XCTAssertEqual(entries[0].facts.title, "Sign in")
        XCTAssertEqual(entries[0].facts.frame, CGRect(x: 10, y: 20, width: 80, height: 24))
        // Slice 1 digest is flat.
        XCTAssertTrue(entries.allSatisfy { $0.depth == 0 })
    }

    /// A row with neither a name nor a value is noise and is dropped (mirrors the
    /// AX digest's drop-empty rule).
    func testEntriesDropEmptyRows() {
        let rows: [[String: Any]] = [
            ["role": "button", "name": "", "value": ""],
            ["role": "input", "name": "", "value": "typed text"],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].facts.role, "AXTextField")
        XCTAssertEqual(entries[0].facts.value, "typed text")
    }

    /// An empty evaluate result shapes to an honest empty digest — never a
    /// fabricated row.
    func testEntriesEmptyIsHonestEmpty() {
        XCTAssertEqual(CDPDigest.entries(fromEvaluate: []).count, 0)
    }

    /// A zero-sized / missing box yields no frame (honest "no frame"), never a
    /// fabricated box.
    func testZeroBoxHasNoFrame() {
        let rows: [[String: Any]] = [
            ["role": "a", "name": "hidden", "x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].facts.frame)
    }

    /// The browser-surface routing hint: a browser bundle id probes CDP; a native
    /// app (or nil bundle) never does.
    func testIsBrowserSurfaceHint() {
        XCTAssertTrue(WebSurface.isBrowserSurface(bundleID: "com.brave.Browser"))
        XCTAssertTrue(WebSurface.isBrowserSurface(bundleID: "com.google.Chrome"))
        XCTAssertTrue(WebSurface.isBrowserSurface(bundleID: "com.apple.Safari"))
        XCTAssertTrue(WebSurface.isBrowserSurface(bundleID: "org.mozilla.firefox"))
        XCTAssertTrue(WebSurface.isBrowserSurface(bundleID: "com.operasoftware.Opera"))
        XCTAssertTrue(WebSurface.isBrowserSurface(bundleID: "com.microsoft.edgemac"))

        XCTAssertFalse(WebSurface.isBrowserSurface(bundleID: "com.apple.finder"))
        XCTAssertFalse(WebSurface.isBrowserSurface(bundleID: "com.apple.calculator"))
        XCTAssertFalse(WebSurface.isBrowserSurface(bundleID: nil))
    }
}
