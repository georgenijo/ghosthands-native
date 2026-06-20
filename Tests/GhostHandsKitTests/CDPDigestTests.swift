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

    // MARK: - web-digest-aria — ARIA interactive roles / [onclick] / <summary> /
    // contenteditable surfaced + ref-stamped by the digest.
    //
    // NOTE ON SURFACE: the interactive GATE (which DOM elements get gathered + a
    // `data-gh-ref` stamped) lives in the embedded `CDPDigest.interactiveJS` /
    // `collectRowJS` JS strings, evaluated IN THE PAGE — there is no pure-Swift
    // gate to unit-test directly (driving a live browser in a test is banned).
    // The nearest PURE Swift surfaces are: (1) `axRole(for:)`, the role→AX-role
    // renderer the digest uses for the new ARIA roles, and (2) `entries(fromEvaluate:)`,
    // which must KEEP a ref-stamped ARIA/contenteditable/onclick row (a stamped row
    // is an actionable control, never noise). Both are exercised below over
    // FABRICATED rows — no socket, no browser.

    /// The new ARIA interactive roles a non-native control reports (a
    /// `div[role=switch]`, a `<summary>`, `role=menuitem`, …) render as a clean
    /// AX-ish role on the digest line, not a raw HTML word. Additive — the original
    /// mappings are unchanged.
    func testAxRoleMapsAriaInteractiveRoles() {
        XCTAssertEqual(CDPDigest.axRole(for: "switch"), "AXCheckBox")
        XCTAssertEqual(CDPDigest.axRole(for: "menuitemcheckbox"), "AXCheckBox")
        XCTAssertEqual(CDPDigest.axRole(for: "menuitemradio"), "AXRadioButton")
        XCTAssertEqual(CDPDigest.axRole(for: "tab"), "AXTab")
        XCTAssertEqual(CDPDigest.axRole(for: "menuitem"), "AXMenuItem")
        XCTAssertEqual(CDPDigest.axRole(for: "option"), "AXMenuItem")
        XCTAssertEqual(CDPDigest.axRole(for: "slider"), "AXSlider")
        XCTAssertEqual(CDPDigest.axRole(for: "spinbutton"), "AXStepper")
        XCTAssertEqual(CDPDigest.axRole(for: "searchbox"), "AXTextField")
        XCTAssertEqual(CDPDigest.axRole(for: "summary"), "AXButton")
        // Original mappings untouched (no regression).
        XCTAssertEqual(CDPDigest.axRole(for: "button"), "AXButton")
        XCTAssertEqual(CDPDigest.axRole(for: "link"), "AXLink")
        XCTAssertEqual(CDPDigest.axRole(for: "checkbox"), "AXCheckBox")
        XCTAssertEqual(CDPDigest.axRole(for: "combobox"), "AXComboBox")
    }

    /// An ARIA-role row the digest now stamps (e.g. a `div[role=button]`) carries
    /// its `@eN` ref through to the entry and renders the handle on the line — so an
    /// Electron `div[role=button]` is addressable, not invisible. The role surfaces
    /// as AXButton even though the underlying tag is a div.
    func testAriaButtonRowStampedAndAddressable() {
        let rows: [[String: Any]] = [
            ["ref": "e1", "role": "button", "name": "Send",
             "x": 12.0, "y": 30.0, "w": 64.0, "h": 28.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].ref, "@e1")
        XCTAssertEqual(entries[0].facts.role, "AXButton")
        XCTAssertEqual(WebDigest.line(entries[0]),
                       "@e1 AXButton \"Send\" @(12,30 64×28)")
    }

    /// A contenteditable editor (Cursor/Lexical/ProseMirror compose box) and a bare
    /// `<div onclick>` are non-native interactive controls: the digest now stamps a
    /// ref, so even with an empty value they SURVIVE shaping (a ref-stamped row is an
    /// actionable control, never dropped as noise) and their raw role passes through
    /// honestly (a div is a div, never fabricated into a button).
    func testContenteditableAndOnclickRowsKept() {
        let rows: [[String: Any]] = [
            // A contenteditable composer: role is its tag (no aria role), empty value.
            ["ref": "e1", "role": "div", "name": "Ask anything", "value": "",
             "x": 0.0, "y": 0.0, "w": 320.0, "h": 40.0],
            // A clickable <div onclick> with no name/value but a stamped ref.
            ["ref": "e2", "role": "div", "name": "", "value": "",
             "x": 5.0, "y": 5.0, "w": 20.0, "h": 20.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].ref, "@e1")
        XCTAssertEqual(entries[0].facts.role, "div")     // honest passthrough, not faked
        XCTAssertEqual(entries[0].facts.title, "Ask anything")
        XCTAssertEqual(entries[1].ref, "@e2")            // kept purely on the ref signal
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
