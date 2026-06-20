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

    // MARK: - Pure offset-accumulation math (read-side rect translation)

    /// A plain, un-framed element has an EMPTY frame chain → offset {0,0}: its rect is
    /// already top-level, never shifted. This is the no-op the digest relies on so a
    /// top-level control is unchanged when iframe translation is applied uniformly.
    func testEmptyChainIsZeroOffset() {
        XCTAssertEqual(WebFrameOffset.accumulate([]), .zero)
        let r = CGRect(x: 12, y: 34, width: 56, height: 78)
        XCTAssertEqual(WebFrameOffset.translate(r, by: []), r)
    }

    /// A chain of SAME-ORIGIN frame offsets SUMS — nesting an element two iframes deep
    /// adds both frames' offsets, landing it in top-level coords. This is the core
    /// translation the read side (`ghCollectRow`) and the find ranking now apply.
    func testSameOriginChainSums() {
        let chain: [WebFrameOffset.Link] = [
            .sameOrigin(dx: 100, dy: 40),   // the element's own iframe, offset in its parent
            .sameOrigin(dx: 8, dy: 200),    // that parent iframe, offset in the top document
        ]
        XCTAssertEqual(WebFrameOffset.accumulate(chain), CGPoint(x: 108, y: 240))
        // A frame-local rect at (10,10) lands at (118,250) in top-level coords.
        let local = CGRect(x: 10, y: 10, width: 30, height: 20)
        XCTAssertEqual(WebFrameOffset.translate(local, by: chain),
                       CGRect(x: 118, y: 250, width: 30, height: 20))
    }

    /// A single same-origin frame is the common case (one iframe deep): the element's
    /// rect shifts by exactly that frame's offset.
    func testSingleSameOriginFrame() {
        let chain: [WebFrameOffset.Link] = [.sameOrigin(dx: 50, dy: 300)]
        XCTAssertEqual(WebFrameOffset.accumulate(chain), CGPoint(x: 50, y: 300))
    }

    /// A CROSS-ORIGIN frame in the chain STOPS the accumulation: we keep only the
    /// same-origin partial sum gathered up to the boundary and never sum past a frame
    /// whose geometry we cannot honestly read. (In practice a cross-origin frame's
    /// CONTENTS are unreachable too — `contentDocument` throws — so this is the honest
    /// guard, never a guessed offset.)
    func testCrossOriginFrameStopsAccumulation() {
        let chain: [WebFrameOffset.Link] = [
            .sameOrigin(dx: 20, dy: 30),
            .crossOrigin,                   // boundary: stop here
            .sameOrigin(dx: 999, dy: 999),  // beyond the boundary — must NOT be summed
        ]
        XCTAssertEqual(WebFrameOffset.accumulate(chain), CGPoint(x: 20, y: 30))
    }

    /// A leading cross-origin link (the element's very own frame is cross-origin —
    /// a defensive case we never actually reach) contributes ZERO, not a guess.
    func testLeadingCrossOriginYieldsZero() {
        XCTAssertEqual(WebFrameOffset.accumulate([.crossOrigin]), .zero)
        XCTAssertEqual(WebFrameOffset.accumulate([.crossOrigin, .sameOrigin(dx: 5, dy: 5)]),
                       .zero)
    }

    // MARK: - Generated JS wires in the offset translation

    /// `ghFrameOffset` lives in the shared pierce helper, walks UP the `frameElement`
    /// chain, and is GUARDED by try/catch so a cross-origin ancestor stops the walk
    /// (the same-origin partial sum is kept, never a guessed offset).
    func testShadowPierceHelperDefinesFrameOffsetHonestly() {
        let js = CDPDigest.shadowPierceJS
        XCTAssertTrue(js.contains("ghFrameOffset"))
        XCTAssertTrue(js.contains("frameElement"))
        XCTAssertTrue(js.contains("catch"))
    }

    /// The read-side row builder applies the frame offset so an iframe element's rect
    /// is reported in TOP-LEVEL coords (`x: r.x + off.x`), keeping `see` / occlusion /
    /// pixel-targeting consistent with top-level controls.
    func testCollectRowTranslatesIframeRectToTopLevel() {
        let js = CDPDigest.collectRowJS
        XCTAssertTrue(js.contains("ghFrameOffset(el)"))
        XCTAssertTrue(js.contains("r.x + off.x"))
        XCTAssertTrue(js.contains("r.y + off.y"))
    }

    /// The see-the-words find ranking also translates an iframe candidate's rect to
    /// top-level coords before the viewport test + top-most (y then x) sort, so an
    /// iframe control can't out-rank a top-level one on its small frame-local y.
    func testFindRankingTranslatesIframeRect() {
        let exp = WebFind.resolveExpression(text: "Send", nth: nil, fillable: false)
        XCTAssertTrue(exp.contains("ghFrameOffset(el)"))
        XCTAssertTrue(exp.contains("r.top + off.y"))
    }

    /// The click gate is DELIBERATELY KEPT: the read side now translates rects, but
    /// the inFrame REFUSE still fires — because the occlusion hit-test can't see a
    /// top-document overlay across the frame boundary, so a translated dispatch is not
    /// provably safe. An honest refuse beats a click at unprovable-occlusion geometry.
    func testClickGateStaysRefuseForIframe() {
        XCTAssertTrue(WebActuate.isInFrame(from: ["found": true, "inFrame": true]))
    }
}
