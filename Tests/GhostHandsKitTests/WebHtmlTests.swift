import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE cores of the CDP Slice 3 read verbs (`web html` / `web
/// eval`), over FABRICATED `[String: Any]` probe/reply dictionaries. No socket, no
/// browser. Verifies html shaping (found/not-found, attrs, computed subset,
/// truncation, render sections) and eval classification (value stringify across
/// types + the exceptionDetails → throw mapping).
final class WebHtmlTests: XCTestCase {
    // MARK: - web html: shape

    /// A `found` probe shapes into the tag, outerHTML, name-sorted attributes, and
    /// the curated computed subset in `computedProps` order.
    func testShapeFoundElement() throws {
        let probe: [String: Any] = [
            "found": true,
            "tag": "a",
            "outerHTML": "<a href=\"/x\" class=\"btn\">Go</a>",
            "truncated": false,
            "attrs": ["href": "/x", "class": "btn", "data-id": "7"],
            "computed": [
                "display": "inline-block", "visibility": "visible",
                "position": "static", "color": "rgb(0, 0, 0)",
                "backgroundColor": "rgba(0, 0, 0, 0)", "fontSize": "16px",
                "width": "40px", "height": "20px",
            ],
        ]
        let s = try WebHtml.shape(probe, selector: "a", app: "Brave")
        XCTAssertEqual(s.tag, "a")
        XCTAssertEqual(s.outerHTML, "<a href=\"/x\" class=\"btn\">Go</a>")
        XCTAssertFalse(s.truncated)
        // Attributes are name-sorted for a stable render.
        XCTAssertEqual(s.attributes.map { $0.name }, ["class", "data-id", "href"])
        XCTAssertEqual(s.attributes.first { $0.name == "href" }?.value, "/x")
        // Computed is in the fixed curated order, all 8 present.
        XCTAssertEqual(s.computed.map { $0.name }, WebHtml.computedProps)
        XCTAssertEqual(s.computed.first { $0.name == "display" }?.value, "inline-block")
    }

    /// A `found: false` probe is the REFUSE — `shape` throws `selectorNotFound`
    /// carrying the selector + app, never a fabricated empty shell.
    func testShapeNotFoundThrows() {
        let probe: [String: Any] = ["found": false]
        XCTAssertThrowsError(try WebHtml.shape(probe, selector: "#missing", app: "Brave")) {
            guard case let GhostHandsError.selectorNotFound(selector, app) = $0 else {
                return XCTFail("expected selectorNotFound, got \($0)")
            }
            XCTAssertEqual(selector, "#missing")
            XCTAssertEqual(app, "Brave")
        }
    }

    /// An element with no attributes shapes to an empty attribute list (honest
    /// "none"), never a fabricated entry.
    func testShapeNoAttributes() throws {
        let probe: [String: Any] = [
            "found": true, "tag": "div", "outerHTML": "<div></div>",
            "attrs": [String: Any](), "computed": [String: Any](),
        ]
        let s = try WebHtml.shape(probe, selector: "div", app: "Chrome")
        XCTAssertTrue(s.attributes.isEmpty)
    }

    /// A curated computed prop the page DIDN'T return is reported as "(not
    /// reported)" — the fixed subset always renders fully, never silently shortened.
    func testShapeMissingComputedPropIsNotReported() throws {
        let probe: [String: Any] = [
            "found": true, "tag": "span", "outerHTML": "<span>hi</span>",
            "attrs": [String: Any](),
            // Only one of the eight props returned.
            "computed": ["display": "inline"],
        ]
        let s = try WebHtml.shape(probe, selector: "span", app: "Brave")
        XCTAssertEqual(s.computed.count, WebHtml.computedProps.count)
        XCTAssertEqual(s.computed.first { $0.name == "display" }?.value, "inline")
        XCTAssertEqual(s.computed.first { $0.name == "color" }?.value, WebHtml.notReported)
    }

    /// The truncation flag carries through so the render can flag a capped dump
    /// honestly.
    func testShapeTruncatedFlag() throws {
        let probe: [String: Any] = [
            "found": true, "tag": "body", "outerHTML": String(repeating: "x", count: 100),
            "truncated": true, "attrs": [String: Any](), "computed": [String: Any](),
        ]
        let s = try WebHtml.shape(probe, selector: "body", app: "Brave")
        XCTAssertTrue(s.truncated)
    }

    /// A non-string attribute value is stringified tolerantly (a number), and an
    /// empty-string value (e.g. a boolean attribute like `disabled`) is preserved.
    func testShapeAttrValueCoercion() throws {
        let probe: [String: Any] = [
            "found": true, "tag": "input", "outerHTML": "<input disabled tabindex=2>",
            "attrs": ["disabled": "", "tabindex": NSNumber(value: 2)],
            "computed": [String: Any](),
        ]
        let s = try WebHtml.shape(probe, selector: "input", app: "Brave")
        XCTAssertEqual(s.attributes.first { $0.name == "disabled" }?.value, "")
        XCTAssertEqual(s.attributes.first { $0.name == "tabindex" }?.value, "2")
    }

    // MARK: - web html: render

    /// The render is clearly sectioned: a tag header, then outerHTML, attributes,
    /// computed — in that order, with the curated props all present.
    func testRenderSections() throws {
        let probe: [String: Any] = [
            "found": true, "tag": "a", "outerHTML": "<a>Go</a>",
            "attrs": ["href": "/x"],
            "computed": ["display": "inline"],
        ]
        let s = try WebHtml.shape(probe, selector: "a", app: "Brave")
        let out = WebHtml.render(s)
        XCTAssertTrue(out.contains("<a>"))
        XCTAssertTrue(out.contains("── outerHTML ──"))
        XCTAssertTrue(out.contains("<a>Go</a>"))
        XCTAssertTrue(out.contains("── attributes ──"))
        XCTAssertTrue(out.contains("href"))
        XCTAssertTrue(out.contains("── computed ──"))
        XCTAssertTrue(out.contains("display: inline"))
        XCTAssertTrue(out.contains("color: \(WebHtml.notReported)"))
        // Section order: outerHTML before attributes before computed.
        let html = out.range(of: "── outerHTML ──")!
        let attrs = out.range(of: "── attributes ──")!
        let comp = out.range(of: "── computed ──")!
        XCTAssertTrue(html.lowerBound < attrs.lowerBound)
        XCTAssertTrue(attrs.lowerBound < comp.lowerBound)
    }

    /// An attribute-less element renders "(none)" rather than an empty section —
    /// honest, never a blank that reads like a parse error.
    func testRenderNoAttributes() throws {
        let probe: [String: Any] = [
            "found": true, "tag": "div", "outerHTML": "<div></div>",
            "attrs": [String: Any](), "computed": [String: Any](),
        ]
        let out = WebHtml.render(try WebHtml.shape(probe, selector: "div", app: "Brave"))
        XCTAssertTrue(out.contains("(none)"))
    }

    /// A truncated dump renders the "(truncated…)" note so a capped slice is never
    /// mistaken for the whole node.
    func testRenderTruncationNote() throws {
        let probe: [String: Any] = [
            "found": true, "tag": "body", "outerHTML": "xxxx",
            "truncated": true, "attrs": [String: Any](), "computed": [String: Any](),
        ]
        let out = WebHtml.render(try WebHtml.shape(probe, selector: "body", app: "Brave"))
        XCTAssertTrue(out.contains("truncated"))
        XCTAssertTrue(out.contains("\(WebHtml.outerHTMLCap)"))
    }

    // MARK: - web eval: classify + stringify

    /// A string value classifies to `.value` and stringifies verbatim (the common
    /// case — text the page produced).
    func testEvalStringValue() {
        let reply: [String: Any] = ["result": ["type": "string", "value": "Example Domain"]]
        XCTAssertEqual(WebEval.classify(reply), .value("Example Domain"))
    }

    /// A numeric value renders as its number; a boolean renders JS-style
    /// true/false, NEVER as 1/0.
    func testEvalNumberAndBool() {
        let num: [String: Any] = ["result": ["type": "number", "value": NSNumber(value: 42)]]
        XCTAssertEqual(WebEval.classify(num), .value("42"))

        let boolReply: [String: Any] = ["result": ["type": "boolean", "value": true]]
        XCTAssertEqual(WebEval.classify(boolReply), .value("true"))

        let falseReply: [String: Any] = ["result": ["type": "boolean", "value": false]]
        XCTAssertEqual(WebEval.classify(falseReply), .value("false"))
    }

    /// An array / object value re-encodes to compact JSON (sorted keys for a stable
    /// render), never a Swift `["a": ...]` debug dump.
    func testEvalArrayAndObject() {
        let arr: [String: Any] = ["result": ["type": "object", "value": [1, 2, 3]]]
        XCTAssertEqual(WebEval.classify(arr), .value("[1,2,3]"))

        let obj: [String: Any] = [
            "result": ["type": "object", "value": ["b": 2, "a": 1]],
        ]
        XCTAssertEqual(WebEval.classify(obj), .value("{\"a\":1,\"b\":2}"))
    }

    /// A JS `undefined` (no `value` key) stringifies to the visible token
    /// `undefined`, never a blank line that reads like a missing result.
    func testEvalUndefined() {
        let reply: [String: Any] = ["result": ["type": "undefined"]]
        XCTAssertEqual(WebEval.classify(reply), .value("undefined"))
    }

    /// A JS `null` value stringifies to the token `null`.
    func testEvalNull() {
        let reply: [String: Any] = ["result": ["type": "object", "subtype": "null",
                                               "value": NSNull()]]
        XCTAssertEqual(WebEval.classify(reply), .value("null"))
    }

    /// A non-serializable object with no `value` (a DOM node) reports its
    /// `description`, else its `className`/`type` — an honest token, never a crash.
    func testEvalNonSerializableObject() {
        let withDesc: [String: Any] = [
            "result": ["type": "object", "className": "HTMLDivElement",
                       "description": "div#main"],
        ]
        XCTAssertEqual(WebEval.classify(withDesc), .value("div#main"))

        let classOnly: [String: Any] = [
            "result": ["type": "object", "className": "Window"],
        ]
        XCTAssertEqual(WebEval.classify(classOnly), .value("Window"))
    }

    /// A reply with `exceptionDetails` classifies to `.threw` carrying the thrown
    /// Error's description — the eval honesty boundary (a page throw is a refuse
    /// signal, NEVER a fake empty success).
    func testEvalExceptionFromDescription() {
        let reply: [String: Any] = [
            "result": ["type": "object", "subtype": "error"],
            "exceptionDetails": [
                "text": "Uncaught",
                "exception": ["description": "ReferenceError: foo is not defined"],
            ],
        ]
        XCTAssertEqual(WebEval.classify(reply),
                       .threw(message: "ReferenceError: foo is not defined"))
    }

    /// When no `exception.description` is present, the throw message falls back to
    /// the top-level `text`.
    func testEvalExceptionFallsBackToText() {
        let reply: [String: Any] = [
            "exceptionDetails": ["text": "Uncaught SyntaxError"],
        ]
        XCTAssertEqual(WebEval.classify(reply), .threw(message: "Uncaught SyntaxError"))
    }

    /// An exceptionDetails with neither description nor text still classifies to a
    /// throw (with a generic note) — a throw is never downgraded to a value.
    func testEvalExceptionGenericFallback() {
        let reply: [String: Any] = ["exceptionDetails": [String: Any]()]
        XCTAssertEqual(WebEval.classify(reply), .threw(message: "page-side JS exception"))
    }

    /// An empty reply (no result, no exception) is an honest `undefined` value, not
    /// a throw — distinguishing a clean no-value result from a page error.
    func testEvalEmptyReplyIsUndefinedValue() {
        XCTAssertEqual(WebEval.classify([:]), .value("undefined"))
    }
}
