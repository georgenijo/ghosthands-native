import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE half of the no-JS extraction verbs (issue #11): the per-verb
/// probe expression and the shaping of a FABRICATED reply into values / count / a
/// refuse. No socket, no browser. The honesty boundary under test: an invalid
/// selector (and, for text/attr, a no-match) REFUSES, while `count` of nothing is 0.
final class WebExtractTests: XCTestCase {
    // MARK: probe expressions embed the selector/name safely

    func testProbesEmbedSelectorAsJSONLiteral() {
        XCTAssertTrue(WebExtract.textProbeExpression(selector: ".a")
            .contains("querySelectorAll(\".a\")"))
        XCTAssertTrue(WebExtract.countProbeExpression(selector: "#x")
            .contains("querySelectorAll(\"#x\")"))
        let attr = WebExtract.attrProbeExpression(selector: "a", name: "href")
        XCTAssertTrue(attr.contains("getAttribute(\"href\")"))
        // A selector with a quote can't break out — it is JSON-escaped.
        XCTAssertTrue(WebExtract.textProbeExpression(selector: "a[x=\"y\"]")
            .contains("\"a[x=\\\"y\\\"]\""))
    }

    // MARK: text — values in order; invalid OR empty REFUSES

    func testTextShapesValuesInOrder() throws {
        let dict: [String: Any] = ["ok": true, "texts": ["First", "Second", "Third"]]
        let got = try WebExtract.shapeText(dict, selector: ".h", app: "Brave")
        XCTAssertEqual(got.rendered, ["First", "Second", "Third"])
        XCTAssertEqual(got.count, 3)
    }

    func testTextInvalidSelectorRefuses() {
        XCTAssertThrowsError(try WebExtract.shapeText(["ok": false], selector: ":::bad", app: "Brave")) {
            guard case GhostHandsError.selectorNotFound = $0 else {
                return XCTFail("expected selectorNotFound, got \($0)")
            }
        }
    }

    func testTextNoMatchRefuses() {
        // A valid selector that matched nothing — asking for text of no element refuses.
        XCTAssertThrowsError(try WebExtract.shapeText(["ok": true, "texts": []],
                                                      selector: ".none", app: "Brave"))
    }

    // MARK: attr — absent attribute is nil (not a refuse), values keep order

    func testAttrShapesNullAsAbsent() throws {
        let dict: [String: Any] = ["ok": true, "values": ["https://a", NSNull(), "https://c"]]
        let got = try WebExtract.shapeAttr(dict, selector: "a", app: "Brave")
        XCTAssertEqual(got.values, ["https://a", nil, "https://c"])
        XCTAssertEqual(got.rendered, ["https://a", "", "https://c"])  // nil → empty line
    }

    func testAttrInvalidOrEmptyRefuses() {
        XCTAssertThrowsError(try WebExtract.shapeAttr(["ok": false], selector: "x", app: "B"))
        XCTAssertThrowsError(try WebExtract.shapeAttr(["ok": true, "values": []],
                                                      selector: ".none", app: "B"))
    }

    // MARK: count — 0 is honest; only an invalid selector refuses

    func testCountValidZeroIsHonest() throws {
        XCTAssertEqual(try WebExtract.shapeCount(["ok": true, "count": 0],
                                                 selector: ".none", app: "B"), 0)
        XCTAssertEqual(try WebExtract.shapeCount(["ok": true, "count": 42],
                                                 selector: ".athing", app: "B"), 42)
    }

    func testCountInvalidSelectorRefuses() {
        XCTAssertThrowsError(try WebExtract.shapeCount(["ok": false], selector: ":::", app: "B")) {
            guard case GhostHandsError.selectorNotFound = $0 else {
                return XCTFail("expected selectorNotFound, got \($0)")
            }
        }
    }

    // MARK: scoped read expression roots at the container + reports found

    func testScopedExpressionRootsAtContainerAndStampsRefs() {
        let expr = CDPDigest.scopedEvaluateExpression(container: "#main")
        // The container is resolved PIERCING shadow roots / same-origin iframes
        // (a scope inside a web component is reachable), with its selector embedded
        // as a JSON literal — replaces the old boundary-stopping document.querySelector.
        XCTAssertTrue(expr.contains("ghQuery(\"#main\")"))
        XCTAssertTrue(expr.contains("node.querySelectorAll"))   // scoped walk, not document-wide
        XCTAssertTrue(expr.contains("found: false"))            // missing container → refuse signal
        XCTAssertTrue(expr.contains("data-gh-ref"))             // refs still stamped within scope
        // The scoped collection ALSO descends into nested open shadow roots /
        // same-origin iframes within the container (the piercing the feature adds).
        XCTAssertTrue(expr.contains("shadowRoot"))
        XCTAssertTrue(expr.contains("contentDocument"))
    }
}
