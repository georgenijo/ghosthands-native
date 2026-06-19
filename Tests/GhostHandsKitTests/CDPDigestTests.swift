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

    /// REGRESSION (the eval-found bug): a REF-STAMPED interactive row is KEPT even
    /// with no name, no value, AND no state — it's an actionable control, never
    /// noise. A bare/label-wrapped text input (httpbin's "Customer name:") that read
    /// empty pre-fill was being DROPPED, hiding fillable fields from `web read`. The
    /// ref is the keep signal; a ref-less empty row (real noise) still drops.
    func testEntriesKeepRefStampedEmptyInteractive() {
        let rows: [[String: Any]] = [
            // A stamped-but-empty input — must survive (actionable via @e1).
            ["ref": "e1", "role": "input", "name": "", "value": "",
             "x": 10.0, "y": 20.0, "w": 120.0, "h": 24.0],
            // A ref-less empty node — still dropped (genuine noise).
            ["ref": "", "role": "h2", "name": "", "value": ""],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].ref, "@e1")
        XCTAssertEqual(entries[0].facts.role, "AXTextField")
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

    /// Issue #7 — interactive rows carry their stamped `@eN` ref through to the
    /// entry; a text/heading row (no ref stamped) has nil ref. The bare id from the
    /// page ("e1") is surfaced as the `@e1` handle the digest prints.
    func testEntriesCarryRefsForInteractiveOnly() {
        let rows: [[String: Any]] = [
            ["ref": "e1", "role": "a", "name": "Sign in",
             "x": 10.0, "y": 20.0, "w": 80.0, "h": 24.0],
            ["ref": "e2", "role": "input", "name": "", "value": "typed",
             "x": 0.0, "y": 0.0, "w": 50.0, "h": 20.0],
            ["ref": "", "role": "h1", "name": "Welcome",
             "x": 0.0, "y": 0.0, "w": 200.0, "h": 40.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.map { $0.ref }, ["@e1", "@e2", nil])
    }

    /// A ref'd entry renders the handle at the START of the digest line, so look
    /// and click share one address: `@e1 AXLink "Sign in" @(…)`.
    func testRefRendersOnDigestLine() {
        let rows: [[String: Any]] = [
            ["ref": "e7", "role": "button", "name": "Search",
             "x": 412.0, "y": 240.0, "w": 86.0, "h": 32.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(WebDigest.line(entries[0]),
                       "@e7 AXButton \"Search\" @(412,240 86×32)")
    }

    // MARK: - Issue #8 — form-control state surfaced inline

    /// A checkbox/radio carries `checked` (true/false), and the row is KEPT even
    /// with no label/value — its state IS the signal. The line renders `checked=…`.
    func testCheckboxStateKeptAndRendered() {
        let rows: [[String: Any]] = [
            ["ref": "e1", "role": "checkbox", "name": "", "value": "",
             "checked": true, "x": 0.0, "y": 0.0, "w": 16.0, "h": 16.0],
            ["ref": "e2", "role": "radio", "name": "", "value": "",
             "checked": false, "x": 0.0, "y": 0.0, "w": 16.0, "h": 16.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.count, 2)                 // unlabeled but KEPT (state signal)
        XCTAssertEqual(entries[0].facts.role, "AXCheckBox")
        XCTAssertEqual(entries[0].state?.checked, true)
        XCTAssertTrue(WebDigest.line(entries[0]).contains("checked=true"))
        XCTAssertEqual(entries[1].facts.role, "AXRadioButton")
        XCTAssertTrue(WebDigest.line(entries[1]).contains("checked=false"))
    }

    /// A `<select>` reports its chosen option text as `selected="…"`; a disclosure
    /// reports `expanded=…`; a disabled control flags `(disabled)`.
    func testSelectExpandedAndDisabledStates() {
        let rows: [[String: Any]] = [
            ["ref": "e1", "role": "select", "name": "Country", "value": "us",
             "selected": "United States", "x": 0.0, "y": 0.0, "w": 120.0, "h": 24.0],
            ["ref": "e2", "role": "button", "name": "Menu",
             "expanded": false, "x": 0.0, "y": 0.0, "w": 40.0, "h": 24.0],
            ["ref": "e3", "role": "button", "name": "Submit", "disabled": true,
             "x": 0.0, "y": 0.0, "w": 50.0, "h": 24.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries[0].state?.selected, "United States")
        XCTAssertTrue(WebDigest.line(entries[0]).contains("selected=\"United States\""))
        XCTAssertEqual(entries[1].state?.expanded, false)
        XCTAssertTrue(WebDigest.line(entries[1]).contains("expanded=false"))
        XCTAssertEqual(entries[2].facts.enabled, false)
        XCTAssertTrue(WebDigest.line(entries[2]).contains("(disabled)"))
    }

    /// A plain control with NO state has a nil `state` and renders no state tokens —
    /// the state surfacing is purely additive (no `checked=`/`selected=` noise).
    func testNoStateRowsStayClean() {
        let rows: [[String: Any]] = [
            ["ref": "e1", "role": "a", "name": "Home",
             "x": 0.0, "y": 0.0, "w": 40.0, "h": 18.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertNil(entries[0].state)
        let line = WebDigest.line(entries[0])
        XCTAssertFalse(line.contains("checked"))
        XCTAssertFalse(line.contains("selected"))
        XCTAssertFalse(line.contains("expanded"))
    }

    /// `optBool` distinguishes a real `false` from an absent/null field — so a
    /// checkbox shows `checked=false` while a non-checkable control shows nothing.
    func testOptBoolDistinguishesFalseFromAbsent() {
        XCTAssertEqual(WebActuate.optBool(false), false)
        XCTAssertEqual(WebActuate.optBool(true), true)
        XCTAssertNil(WebActuate.optBool(nil))
        XCTAssertNil(WebActuate.optBool(NSNull()))
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
