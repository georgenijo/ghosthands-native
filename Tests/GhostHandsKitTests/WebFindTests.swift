import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE half of the see-the-words backup (issue #7's secondary
/// path): the resolver expression (candidate set, ranking, stamp) and the
/// classification of its reply into found / none / out-of-range. No socket, no
/// browser. The live actuation reuses the same occlusion+verify path as a ref/CSS
/// click, tested elsewhere.
final class WebFindTests: XCTestCase {
    // MARK: decide — found / none / out-of-range

    func testDecideFound() {
        let d = WebFind.decide(["found": true, "count": 3, "label": "Sign in"])
        XCTAssertEqual(d, .found(label: "Sign in", count: 3))
    }

    func testDecideNoneWhenNoMatch() {
        XCTAssertEqual(WebFind.decide(["found": false, "count": 0]), .none(count: 0))
    }

    func testDecideOutOfRange() {
        // --nth past the list → out-of-range (a refuse), not a silent top pick.
        XCTAssertEqual(WebFind.decide(["found": false, "outOfRange": true, "count": 2]),
                       .outOfRange(count: 2))
    }

    func testDecideEmptyReplyIsNone() {
        XCTAssertEqual(WebFind.decide([:]), .none(count: 0))
    }

    // MARK: resolver expression — candidate set, ranking, safe embedding, stamp

    func testClickResolverShape() {
        let expr = WebFind.resolveExpression(text: "Sign in", nth: nil, fillable: false)
        XCTAssertTrue(expr.contains("\"Sign in\".toLowerCase()"))   // needle embedded as JSON literal
        XCTAssertTrue(expr.contains("role=button"))                 // clickable candidate set
        XCTAssertTrue(expr.contains("innerText"))                   // click label = visible text
        XCTAssertTrue(expr.contains("ll === want"))                 // exact-match ranking
        XCTAssertTrue(expr.contains("? 3 :"))                       // exact > prefix > contains scoring
        XCTAssertTrue(expr.contains("data-gh-find"))                // stamps the chosen pick
        XCTAssertTrue(expr.contains("const nth = -1"))              // nil nth → top-ranked sentinel
    }

    func testFillResolverUsesLabelAndNth() {
        let expr = WebFind.resolveExpression(text: "Email", nth: 1, fillable: true)
        XCTAssertTrue(expr.contains("placeholder"))                 // fill label includes placeholder
        XCTAssertTrue(expr.contains("label[for="))                  // …and an associated <label for>
        XCTAssertTrue(expr.contains("const nth = 1"))               // explicit 0-based nth passed through
        XCTAssertTrue(expr.contains("contenteditable"))             // fillable candidate set
    }

    /// A needle with a quote can't break out of the expression (JSON-escaped).
    func testNeedleIsEscaped() {
        let expr = WebFind.resolveExpression(text: "a\"b", nth: nil, fillable: false)
        XCTAssertTrue(expr.contains("\"a\\\"b\".toLowerCase()"))
    }
}
