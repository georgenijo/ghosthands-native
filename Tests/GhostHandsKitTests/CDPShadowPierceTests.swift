import XCTest
@testable import GhostHandsKit

/// Hermetic — the shadow-root / same-origin-iframe piercing added to the CDP page
/// digest and the @ref-resolution probe expressions. Two layers are testable
/// without a socket or a browser:
///
///   1. The PURE row shaping (`CDPDigest.entries`) over FABRICATED rows that now
///      INCLUDE shadow/iframe-sourced rows — the digest must shape them identically
///      to top-level rows (role map, frame, ref carry-through, drop-empty rule),
///      and a ref stamped inside a shadow root must still surface as a `@eN` handle.
///   2. The generated JS expression strings must STRUCTURALLY wire in the
///      shadow/iframe descent (`ghForEachRoot`/`ghQuery`) and carry the HONESTY
///      guards: open-shadow-only (`el.shadowRoot`) and same-origin-only
///      (`contentDocument` in a try/catch). We assert on the string the page would
///      run, never run it — that is the impure half a live browser proves.
final class CDPShadowPierceTests: XCTestCase {

    // MARK: - Pure row shaping over shadow/iframe-sourced rows

    /// A digest result mixing a top-level row, a row the page collected from inside
    /// an OPEN shadow root, and a row from a SAME-ORIGIN iframe shapes ALL THREE the
    /// same way — the source root is invisible to the shaper (it only sees the rows
    /// the page returned). Roles map, names carry, frames carry, and the
    /// shadow/iframe controls are NOT dropped.
    func testShadowAndIframeRowsShapeLikeTopLevel() {
        let rows: [[String: Any]] = [
            // top-level document
            ["ref": "e1", "role": "button", "name": "Top button",
             "x": 0.0, "y": 0.0, "w": 80.0, "h": 24.0],
            // collected from inside an open shadow root (Cursor-composer-style)
            ["ref": "e2", "role": "textarea", "name": "Ask anything", "value": "",
             "x": 10.0, "y": 200.0, "w": 300.0, "h": 60.0],
            // collected from a same-origin iframe
            ["ref": "e3", "role": "a", "name": "Frame link",
             "x": 5.0, "y": 400.0, "w": 120.0, "h": 18.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map { $0.facts.role },
                       ["AXButton", "AXTextArea", "AXLink"])
        // The shadow-sourced textarea is KEPT (its ref marks it actionable) and its
        // name + frame carry through exactly like a top-level row.
        XCTAssertEqual(entries[1].facts.title, "Ask anything")
        XCTAssertEqual(entries[1].ref, "@e2")
        XCTAssertEqual(entries[1].facts.frame,
                       CGRect(x: 10, y: 200, width: 300, height: 60))
        XCTAssertEqual(entries[2].ref, "@e3")
    }

    /// Ref numbering is monotonic ACROSS roots: the page increments ONE counter as
    /// it walks document → shadow roots → iframes, so refs read e1,e2,e3… with no
    /// collision or reset per root. The shaper carries those distinct ids straight
    /// through — two shadow-sourced controls keep their distinct handles.
    func testRefNumberingMonotonicAcrossRoots() {
        let rows: [[String: Any]] = [
            ["ref": "e1", "role": "a", "name": "Home",
             "x": 0.0, "y": 0.0, "w": 40.0, "h": 18.0],
            ["ref": "e2", "role": "button", "name": "Send",
             "x": 0.0, "y": 0.0, "w": 60.0, "h": 24.0],
            ["ref": "e3", "role": "input", "name": "Search", "value": "",
             "x": 0.0, "y": 0.0, "w": 120.0, "h": 24.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.compactMap { $0.ref }, ["@e1", "@e2", "@e3"])
    }

    /// HONESTY at the shaping boundary: a closed shadow root / cross-origin iframe
    /// yields NO rows from the page (they are skipped in-page, never fabricated), so
    /// the shaper simply sees fewer rows. Modeled here as the page returning only the
    /// reachable rows — the shaper must not invent a row for the skipped content.
    func testSkippedRootsContributeNoFabricatedRows() {
        // The page reached one open-shadow control; a sibling closed shadow root and
        // a cross-origin iframe contributed nothing, so they are simply absent.
        let rows: [[String: Any]] = [
            ["ref": "e1", "role": "button", "name": "Visible",
             "x": 0.0, "y": 0.0, "w": 50.0, "h": 24.0],
        ]
        let entries = CDPDigest.entries(fromEvaluate: rows)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].facts.title, "Visible")
    }

    // MARK: - Generated JS wires in the piercing + honesty guards

    /// The page digest expression descends into every reachable root via
    /// `ghForEachRoot`, and its piercing is HONEST: open-shadow-only and
    /// same-origin-iframe-only, with the cross-origin access guarded by try/catch.
    func testPageDigestExpressionPiercesShadowAndIframe() {
        let exp = CDPDigest.evaluateExpression
        XCTAssertTrue(exp.contains("ghForEachRoot"),
                      "page digest must walk all roots")
        // Open shadow root only (a closed root's `shadowRoot` is null → skipped).
        XCTAssertTrue(exp.contains("el.shadowRoot"))
        // Same-origin iframe only (`contentDocument` access wrapped in try/catch so a
        // cross-origin frame throws → skipped, never fabricated).
        XCTAssertTrue(exp.contains("contentDocument"))
        XCTAssertTrue(exp.contains("IFRAME"))
    }

    /// The scoped digest (`web read --in <css>`) resolves its container with the
    /// shadow-piercing `ghQuery` (so a scope inside a web component is reachable) and
    /// descends into nested open shadow roots / same-origin iframes within it.
    func testScopedDigestExpressionPierces() {
        let exp = CDPDigest.scopedEvaluateExpression(container: "#composer")
        XCTAssertTrue(exp.contains("ghQuery("),
                      "scoped digest must resolve the container piercing shadow roots")
        XCTAssertTrue(exp.contains("shadowRoot"))
        XCTAssertTrue(exp.contains("contentDocument"))
        // The container selector is embedded as a JSON literal (never trusted as code).
        XCTAssertTrue(exp.contains("\"#composer\""))
    }

    /// The shared piercing helper carries BOTH honesty guards in one place: open
    /// shadow roots only, and the same-origin `contentDocument` access inside a
    /// try/catch so a cross-origin frame is skipped silently.
    func testShadowPierceHelperHasHonestyGuards() {
        let js = CDPDigest.shadowPierceJS
        XCTAssertTrue(js.contains("el.shadowRoot"))
        XCTAssertTrue(js.contains("contentDocument"))
        XCTAssertTrue(js.contains("catch"))
        // A cycle guard so a frame re-referencing an ancestor root can't loop.
        XCTAssertTrue(js.contains("seen"))
        XCTAssertTrue(js.contains("ghQuery"))
    }

    /// The @ref-resolution probe used by `web click` re-finds a `[data-gh-ref]`
    /// stamped INSIDE a shadow root via `ghQuery` — otherwise a shadow @ref would
    /// falsely refuse as stale (the plain `document.querySelector` can't cross the
    /// boundary). The data-gh-ref attribute selector is what the read stamped.
    func testProbeExpressionResolvesRefAcrossShadow() {
        let exp = WebActuate.probeExpression(selector: WebRef.selector(forID: "e5"))
        XCTAssertTrue(exp.contains("ghQuery("),
                      "click probe must re-find a ref piercing shadow roots")
        XCTAssertFalse(exp.contains("document.querySelector(sel)"),
                       "the probe must NOT use the boundary-stopping document.querySelector")
        XCTAssertTrue(exp.contains("data-gh-ref=\\\"e5\\\""))
    }

    /// The actuation probe expressions (`focus`, `read-text`, `state`, `select`)
    /// each pierce shadow roots via `ghQuery`, so a `web type`/`web select` against a
    /// shadow-hosted @ref reattaches instead of refusing stale.
    func testActuateProbesPierceShadow() {
        XCTAssertTrue(WebActuate.focusExpression(selector: "#x").contains("ghQuery("))
        XCTAssertTrue(WebActuate.readTextExpression(selector: "#x").contains("ghQuery("))
        XCTAssertTrue(WebActuate.clickStateExpression(selector: "#x").contains("ghQuery("))
        XCTAssertTrue(WebActuate.selectExpression(selector: "#x", value: "v").contains("ghQuery("))
    }

    /// The see-the-words resolver gathers candidates across all roots (so a control
    /// inside a web component is addressable by visible text), and re-finds/stamps the
    /// pick across roots too.
    func testFindResolverGathersAcrossRoots() {
        let exp = WebFind.resolveExpression(text: "Send", nth: nil, fillable: false)
        XCTAssertTrue(exp.contains("ghForEachRoot"),
                      "text find must gather candidates across all roots")
        XCTAssertTrue(exp.contains("data-gh-find"))
    }
}
