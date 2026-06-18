import CoreGraphics
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE deciders + verdicts behind `web click` / `web fill`, over
/// FABRICATED probe dictionaries (the shape `Runtime.evaluate` returns by value).
/// NO socket, NO live browser. Covers the click decision (notFound / covered /
/// proceed + the center math), the click verdict (href-changed → verified), the
/// fill verdict (readback == text → verified), the secure-field gate, and the
/// selector-needs-CDP usage refuse.
final class CDPActuateTests: XCTestCase {
    // MARK: - clickDecision: notFound

    /// A probe object reporting `found: false` is the REFUSE signal → `.notFound`.
    func testClickDecisionNotFoundWhenMissing() {
        XCTAssertEqual(WebActuate.clickDecision(from: ["found": false]), .notFound)
        // An empty object (the page returned a non-object) is also notFound, never
        // a click at a fabricated point.
        XCTAssertEqual(WebActuate.clickDecision(from: [:]), .notFound)
    }

    /// A `found` element with NO usable box (missing or zero-area w/h) is treated
    /// as `.notFound` — we never dispatch a click at a fabricated (0,0) point.
    func testClickDecisionNotFoundWhenNoBox() {
        let zeroBox: [String: Any] = [
            "found": true, "covered": false,
            "x": 5.0, "y": 5.0, "w": 0.0, "h": 0.0,
        ]
        XCTAssertEqual(WebActuate.clickDecision(from: zeroBox), .notFound)

        let missingBox: [String: Any] = ["found": true, "covered": false]
        XCTAssertEqual(WebActuate.clickDecision(from: missingBox), .notFound)
    }

    // MARK: - clickDecision: covered (the occlusion refuse)

    /// A `found`, `covered` object → `.covered(by:)` carrying the cover's tag.
    func testClickDecisionCovered() {
        let probe: [String: Any] = [
            "found": true, "covered": true, "coveredBy": "div",
            "x": 10.0, "y": 10.0, "w": 100.0, "h": 40.0,
        ]
        XCTAssertEqual(WebActuate.clickDecision(from: probe), .covered(by: "div"))
    }

    /// Covered with no coverer tag still refuses, with a placeholder cover name —
    /// never a silent proceed.
    func testClickDecisionCoveredWithoutTag() {
        let probe: [String: Any] = [
            "found": true, "covered": true, "coveredBy": "",
            "x": 0.0, "y": 0.0, "w": 10.0, "h": 10.0,
        ]
        XCTAssertEqual(WebActuate.clickDecision(from: probe), .covered(by: "element"))
    }

    // MARK: - clickDecision: proceed + the center math

    /// A `found`, un-covered element with a real box → `.proceed` at the box
    /// MIDPOINT (x + w/2, y + h/2) within that box. THE center math.
    func testClickDecisionProceedCenterMath() {
        let probe: [String: Any] = [
            "found": true, "covered": false,
            "x": 100.0, "y": 200.0, "w": 80.0, "h": 40.0,
        ]
        guard case let .proceed(center, box) = WebActuate.clickDecision(from: probe) else {
            return XCTFail("expected .proceed")
        }
        XCTAssertEqual(center, CGPoint(x: 140, y: 220)) // 100+40, 200+20
        XCTAssertEqual(box, CGRect(x: 100, y: 200, width: 80, height: 40))
    }

    /// `covered` is honored only when truthy — a `covered: false` proceeds even if
    /// a stale `coveredBy` string lingers in the object.
    func testClickDecisionProceedIgnoresStaleCoveredBy() {
        let probe: [String: Any] = [
            "found": true, "covered": false, "coveredBy": "span",
            "x": 0.0, "y": 0.0, "w": 20.0, "h": 20.0,
        ]
        guard case let .proceed(center, _) = WebActuate.clickDecision(from: probe) else {
            return XCTFail("expected .proceed")
        }
        XCTAssertEqual(center, CGPoint(x: 10, y: 10))
    }

    // MARK: - isSecure gate

    /// The secure-field gate reads the probe's `isSecure` flag.
    func testIsSecureGate() {
        XCTAssertTrue(WebActuate.isSecure(from: ["found": true, "isSecure": true]))
        XCTAssertFalse(WebActuate.isSecure(from: ["found": true, "isSecure": false]))
        XCTAssertFalse(WebActuate.isSecure(from: ["found": true])) // absent → not secure
    }

    // MARK: - clickVerdict (href changed → verified)

    /// A href that CHANGED across the click is the observed navigation → VERIFIED.
    func testClickVerdictNavigationVerified() {
        let v = WebActuate.clickVerdict(hrefBefore: "https://a.test/",
                                        hrefAfter: "https://a.test/next")
        guard case let .verified(evidence) = v else { return XCTFail("expected verified") }
        XCTAssertTrue(evidence.contains("a.test/next"))
    }

    /// A href UNCHANGED across the click → dispatched-unverified (the click landed,
    /// its effect is unproven), NEVER a success claim.
    func testClickVerdictUnchangedDispatched() {
        let v = WebActuate.clickVerdict(hrefBefore: "https://a.test/",
                                        hrefAfter: "https://a.test/")
        guard case let .dispatchedUnverified(reason) = v else {
            return XCTFail("expected dispatchedUnverified")
        }
        XCTAssertTrue(reason.lowercased().contains("unverified"))
    }

    /// A nil before/after (the page URL couldn't be read) is honestly dispatched-
    /// unverified, never verified off a fabricated URL.
    func testClickVerdictNilHrefDispatched() {
        let v = WebActuate.clickVerdict(hrefBefore: nil, hrefAfter: nil)
        guard case .dispatchedUnverified = v else {
            return XCTFail("expected dispatchedUnverified")
        }
    }

    // MARK: - fillVerdict (readback == text → verified)

    /// A read-back EQUAL to the intended text → VERIFIED.
    func testFillVerdictReadbackMatchesVerified() {
        let v = WebActuate.fillVerdict(intended: "swift", readback: "swift")
        guard case let .verified(evidence) = v else { return XCTFail("expected verified") }
        XCTAssertTrue(evidence.contains("swift"))
    }

    /// A read-back that DIFFERS (the field capped / transformed / rejected the set)
    /// → dispatched-unverified, NEVER success.
    func testFillVerdictReadbackDiffersDispatched() {
        let v = WebActuate.fillVerdict(intended: "swiftlang", readback: "swift")
        guard case let .dispatchedUnverified(reason) = v else {
            return XCTFail("expected dispatchedUnverified")
        }
        XCTAssertTrue(reason.lowercased().contains("unverified"))
    }

    /// A field whose value could NOT be read back (nil) → dispatched-unverified.
    func testFillVerdictNilReadbackDispatched() {
        let v = WebActuate.fillVerdict(intended: "x", readback: nil)
        guard case .dispatchedUnverified = v else {
            return XCTFail("expected dispatchedUnverified")
        }
    }

    // MARK: - error mappings (honest descriptions)

    /// `selectorNotFound` names the selector and app and reads as a refuse.
    func testSelectorNotFoundDescription() {
        let e = GhostHandsError.selectorNotFound(selector: "#missing", app: "Brave")
        XCTAssertTrue(e.description.contains("#missing"))
        XCTAssertTrue(e.description.contains("Brave"))
        XCTAssertTrue(e.description.lowercased().contains("refus"))
    }

    /// `elementCovered` names the selector and the covering tag.
    func testElementCoveredDescription() {
        let e = GhostHandsError.elementCovered(selector: "#btn", coveredBy: "div")
        XCTAssertTrue(e.description.contains("#btn"))
        XCTAssertTrue(e.description.contains("div"))
        XCTAssertTrue(e.description.lowercased().contains("overlay"))
    }

    /// `secureFieldUnverifiable` (reused for `web fill` on a password input) reads
    /// as the unverifiable-value refuse.
    func testSecureFieldMapping() {
        let e = GhostHandsError.secureFieldUnverifiable(name: "input[type=password]")
        XCTAssertTrue(e.description.contains("input[type=password]"))
        XCTAssertTrue(e.description.lowercased().contains("verif"))
    }

    /// `selectorNeedsCDP` is the usage refuse when a selector verb is forced onto
    /// `--ax`.
    func testSelectorNeedsCDPDescription() {
        let e = GhostHandsError.selectorNeedsCDP
        XCTAssertTrue(e.description.lowercased().contains("cdp"))
        XCTAssertTrue(e.description.lowercased().contains("selector")
            || e.description.lowercased().contains("ax"))
    }

    // MARK: - exceptionDetails surfacing (a page-side throw is not a clean nil)

    /// A `Runtime.evaluate` reply WITHOUT `exceptionDetails` passes the gate — a
    /// clean evaluate is never mistaken for a thrown one.
    func testEvaluateExceptionGatePassesCleanReply() throws {
        let reply: [String: Any] = ["result": ["value": "https://a.test/"]]
        XCTAssertNoThrow(try GhostHands.throwIfEvaluateException(reply))
    }

    /// A reply carrying `exceptionDetails` is surfaced as `cdpTransport` (a broken
    /// page is distinguished from a clean no-effect), quoting the JS message.
    func testEvaluateExceptionGateThrowsOnPageThrow() {
        let reply: [String: Any] = [
            "exceptionDetails": [
                "text": "Uncaught",
                "exception": ["description": "TypeError: bad setter"],
            ],
        ]
        XCTAssertThrowsError(try GhostHands.throwIfEvaluateException(reply)) { error in
            guard case let GhostHandsError.cdpTransport(reason) = error else {
                return XCTFail("expected cdpTransport, got \(error)")
            }
            XCTAssertTrue(reason.contains("TypeError: bad setter"))
        }
    }

    /// The gate falls back to the top-level `text` when no `exception.description`
    /// is present — still a refuse, never a silent pass.
    func testEvaluateExceptionGateFallsBackToText() {
        let reply: [String: Any] = ["exceptionDetails": ["text": "Uncaught SyntaxError"]]
        XCTAssertThrowsError(try GhostHands.throwIfEvaluateException(reply)) { error in
            guard case let GhostHandsError.cdpTransport(reason) = error else {
                return XCTFail("expected cdpTransport, got \(error)")
            }
            XCTAssertTrue(reason.contains("Uncaught SyntaxError"))
        }
    }

    // MARK: - probe expression embeds the selector safely

    /// The probe expression embeds the selector as a JSON string literal — a quote
    /// in the selector can't break out of the expression (never trusted as code).
    func testProbeExpressionEscapesSelector() {
        let expr = WebActuate.probeExpression(selector: "a[href=\"x\"]")
        // The embedded literal is JSON-escaped, so the raw double-quote does NOT
        // appear unescaped right after `const sel = "a[href=`.
        XCTAssertTrue(expr.contains("\\\""), "selector quotes must be JSON-escaped")
        XCTAssertTrue(expr.contains("elementFromPoint"))
    }
}
