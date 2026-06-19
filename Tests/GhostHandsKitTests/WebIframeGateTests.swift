import XCTest
@testable import GhostHandsKit

/// Hermetic — the iframe click-refuse gate (shadow-pierce honesty fix). A
/// same-origin-iframe target is surfaced for READING but REFUSED for clicking,
/// because the click dispatch + occlusion guard use top-level coords while an
/// iframe's box is iframe-relative (clicking it would land on the wrong point /
/// fabricate a navigation-verified). Shadow-DOM is NOT inFrame.
final class WebIframeGateTests: XCTestCase {

    func testIsInFrameReadsTheProbeFlag() {
        XCTAssertTrue(WebActuate.isInFrame(from: ["found": true, "inFrame": true]))
        XCTAssertFalse(WebActuate.isInFrame(from: ["found": true, "inFrame": false]))
        // Absent flag (older probe / shadow-DOM / light-DOM) → not in a frame.
        XCTAssertFalse(WebActuate.isInFrame(from: ["found": true]))
    }

    func testProbeExpressionComputesInFrameFromOwnerDocument() {
        // The probe derives inFrame from the element's ownerDocument vs the top
        // document — so a shadow-hosted element (same ownerDocument) is NOT inFrame.
        let expr = WebActuate.probeExpression(selector: "#x")
        XCTAssertTrue(expr.contains("inFrame"))
        XCTAssertTrue(expr.contains("ownerDocument"))
    }
}
