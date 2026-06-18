import CoreGraphics
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE pixel-actuation honesty core on FABRICATED buffers.
/// NEVER drives a live app or captures a real screen: every input is a
/// hand-built RGBA buffer / coordinate / fraction. Covers the four required
/// arms: identical buffers ⇒ dispatched; a sufficiently-changed region ⇒
/// verified; an out-of-bounds point ⇒ refuse (bounds gate); coordinate parsing.
final class PixelVerdictTests: XCTestCase {

    // MARK: helpers — fabricated buffers (no capture)

    /// A solid-color WxH RGBA buffer.
    private func solid(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> PixelBuffer {
        var bytes = [UInt8]()
        bytes.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { bytes.append(contentsOf: [r, g, b, a]) }
        return PixelBuffer(width: w, height: h, bytes: bytes)
    }

    // MARK: PixelVerdict.decide

    func testIdenticalBuffersDispatchNotVerified() {
        // Identical before/after ⇒ fraction 0 ⇒ DISPATCHED (clicked, no effect).
        let before = solid(40, 40, r: 10, g: 20, b: 30)
        let after = solid(40, 40, r: 10, g: 20, b: 30)
        let region = PixelRegion.centered(cx: 20, cy: 20, radius: 10)
        let frac = PixelDiff.changedFraction(before: before, after: after, region: region)
        XCTAssertEqual(frac, 0.0)
        XCTAssertEqual(PixelVerdict.decide(regionChangedFraction: frac),
                       .dispatched(fraction: 0.0, observable: true))
    }

    func testFullyChangedRegionIsVerified() {
        // Every pixel differs (well past tolerance) ⇒ fraction 1.0 ⇒ VERIFIED.
        let before = solid(40, 40, r: 0, g: 0, b: 0)
        let after = solid(40, 40, r: 255, g: 255, b: 255)
        let region = PixelRegion.centered(cx: 20, cy: 20, radius: 10)
        let frac = PixelDiff.changedFraction(before: before, after: after, region: region)
        XCTAssertEqual(frac, 1.0)
        XCTAssertEqual(PixelVerdict.decide(regionChangedFraction: frac),
                       .verified(fraction: 1.0))
    }

    func testSubThresholdChangeStaysDispatched() {
        // Below the threshold ⇒ DISPATCHED, never a fabricated success.
        XCTAssertEqual(PixelVerdict.decide(regionChangedFraction: 0.001, threshold: 0.01),
                       .dispatched(fraction: 0.001, observable: true))
    }

    func testAtThresholdIsVerified() {
        // The boundary is inclusive (>= threshold).
        XCTAssertEqual(PixelVerdict.decide(regionChangedFraction: 0.01, threshold: 0.01),
                       .verified(fraction: 0.01))
    }

    func testNotObservableIsAlwaysDispatchedEvenIfFractionHigh() {
        // No Screen Recording / capture failed ⇒ we acted but cannot prove it.
        // Even a high fraction (which should not exist) cannot upgrade to verified.
        XCTAssertEqual(PixelVerdict.decide(regionChangedFraction: 0.99, observable: false),
                       .dispatched(fraction: 0.0, observable: false))
    }

    func testToleranceAbsorbsTinyNoise() {
        // A 1-2 per-channel jitter (capture noise) must NOT register as changed.
        let before = solid(20, 20, r: 100, g: 100, b: 100)
        let after = solid(20, 20, r: 102, g: 99, b: 101)   // within default tol (8)
        let region = PixelRegion.centered(cx: 10, cy: 10, radius: 8)
        let frac = PixelDiff.changedFraction(before: before, after: after, region: region)
        XCTAssertEqual(frac, 0.0)
    }

    func testPartialChangeFractionInRegion() {
        // Change exactly half the rows; the centered region should report ~0.5.
        let w = 20, h = 20
        var bytes = [UInt8]()
        for y in 0..<h {
            for _ in 0..<w {
                // top half white, bottom half black
                let v: UInt8 = y < h / 2 ? 255 : 0
                bytes.append(contentsOf: [v, v, v, 255])
            }
        }
        let after = PixelBuffer(width: w, height: h, bytes: bytes)
        let before = solid(w, h, r: 0, g: 0, b: 0)   // all black
        // Full-buffer region: only the top half differs ⇒ 0.5.
        let region = PixelRegion(x: 0, y: 0, width: w, height: h)
        let frac = PixelDiff.changedFraction(before: before, after: after, region: region)
        XCTAssertEqual(frac, 0.5, accuracy: 0.0001)
    }

    // MARK: PixelDiff edge cases (honest 0 on shapes we can't compare)

    func testShapeMismatchYieldsZero() {
        let before = solid(10, 10, r: 1, g: 2, b: 3)
        let after = solid(12, 10, r: 250, g: 250, b: 250)
        let region = PixelRegion(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(PixelDiff.changedFraction(before: before, after: after, region: region), 0.0)
    }

    func testRegionOutsideBufferYieldsZero() {
        let before = solid(10, 10, r: 0, g: 0, b: 0)
        let after = solid(10, 10, r: 255, g: 255, b: 255)
        // Region entirely off the buffer ⇒ clamps to empty ⇒ 0.
        let region = PixelRegion(x: 100, y: 100, width: 5, height: 5)
        XCTAssertEqual(PixelDiff.changedFraction(before: before, after: after, region: region), 0.0)
    }

    func testRegionClampedToBufferStillMeasures() {
        // A region overhanging the edge is clamped, not rejected: the in-bounds
        // part (all changed) still reports 1.0.
        let before = solid(10, 10, r: 0, g: 0, b: 0)
        let after = solid(10, 10, r: 255, g: 255, b: 255)
        let region = PixelRegion(x: 5, y: 5, width: 100, height: 100)
        XCTAssertEqual(PixelDiff.changedFraction(before: before, after: after, region: region), 1.0)
    }

    func testInvalidBufferYieldsZero() {
        // A buffer whose byte count doesn't match WxH*4 is not honestly diffable.
        let bad = PixelBuffer(width: 10, height: 10, bytes: [0, 0, 0])
        let good = solid(10, 10, r: 255, g: 255, b: 255)
        let region = PixelRegion(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(PixelDiff.changedFraction(before: bad, after: good, region: region), 0.0)
    }

    // MARK: PixelBounds gate — the REFUSE arm (out-of-bounds point)

    func testPointInsideWindowAllows() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 400)
        XCTAssertEqual(PixelBounds.decide(point: CGPoint(x: 250, y: 350), windowFrame: frame),
                       .inside)
    }

    func testPointOutsideWindowRefuses() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 400)
        // left of, above, right of, below
        XCTAssertEqual(PixelBounds.decide(point: CGPoint(x: 50, y: 350), windowFrame: frame), .outside)
        XCTAssertEqual(PixelBounds.decide(point: CGPoint(x: 250, y: 100), windowFrame: frame), .outside)
        XCTAssertEqual(PixelBounds.decide(point: CGPoint(x: 999, y: 350), windowFrame: frame), .outside)
        XCTAssertEqual(PixelBounds.decide(point: CGPoint(x: 250, y: 999), windowFrame: frame), .outside)
    }

    func testWindowEdgesAreHalfOpen() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        // top-left corner is inside; bottom-right (== max) is outside.
        XCTAssertEqual(PixelBounds.decide(point: CGPoint(x: 0, y: 0), windowFrame: frame), .inside)
        XCTAssertEqual(PixelBounds.decide(point: CGPoint(x: 100, y: 100), windowFrame: frame), .outside)
        XCTAssertEqual(PixelBounds.decide(point: CGPoint(x: 99, y: 99), windowFrame: frame), .inside)
    }

    // MARK: PixelRegion.centered geometry

    func testCenteredRegionGeometry() {
        let r = PixelRegion.centered(cx: 50, cy: 60, radius: 10)
        XCTAssertEqual(r.x, 40)
        XCTAssertEqual(r.y, 50)
        XCTAssertEqual(r.width, 21)   // 2*10 + 1
        XCTAssertEqual(r.height, 21)
    }

    // MARK: coordinate parsing (the CLI parses with Double(_:))

    func testCoordinateParsing() {
        XCTAssertEqual(Double("480"), 480)
        XCTAssertEqual(Double("-12.5"), -12.5)
        XCTAssertNil(Double("abc"))
        XCTAssertNil(Double(""))
        XCTAssertNil(Double("12px"))
    }

    // MARK: PixelOutcome honesty invariants (dispatched != verified)

    func testDispatchedOutcomeNotVerified() {
        let o = PixelOutcome(app: "Calc", verb: "click-at", x: 10, y: 20,
                             dispatched: true, verified: false, observable: true,
                             changedFraction: 0.0)
        XCTAssertTrue(o.dispatched)
        XCTAssertFalse(o.verified)
    }

    func testVerifiedOutcomeCarriesFraction() {
        let o = PixelOutcome(app: "Calc", verb: "click-at", x: 10, y: 20,
                             dispatched: true, verified: true, observable: true,
                             changedFraction: 0.42)
        XCTAssertTrue(o.verified)
        XCTAssertEqual(o.changedFraction, 0.42, accuracy: 0.0001)
    }

    // MARK: --visible flag parse + mode selection (PURE, no HID/warp/capture)

    func testFlagParseDefaultIsInvisible() {
        // No flag ⇒ DEFAULT invisible best-effort; positionals untouched/ordered.
        let (mode, pos) = PixelFlags.parse(["480", "300", "Calculator"])
        XCTAssertEqual(mode, .invisible)
        XCTAssertEqual(pos, ["480", "300", "Calculator"])
    }

    func testFlagParseVisibleToggles() {
        // `--visible` present ⇒ visible mode; it is consumed from the positionals.
        let (mode, pos) = PixelFlags.parse(["480", "300", "Calculator", "--visible"])
        XCTAssertEqual(mode, .visible)
        XCTAssertEqual(pos, ["480", "300", "Calculator"])
    }

    func testFlagParseVisibleInAnyOrderPreservesPositionalOrder() {
        // The flag can sit anywhere; the remaining tokens keep their order so the
        // arity guard + Double() parse still see x y app in sequence.
        let (mode, pos) = PixelFlags.parse(["--visible", "100", "200", "400", "200", "Preview"])
        XCTAssertEqual(mode, .visible)
        XCTAssertEqual(pos, ["100", "200", "400", "200", "Preview"])
    }

    func testFlagParseLeavesNonFlagDashTokensAsPositional() {
        // Only the exact `--visible` token is a flag; a negative coord stays positional.
        let (mode, pos) = PixelFlags.parse(["-12", "300", "Calculator"])
        XCTAssertEqual(mode, .invisible)
        XCTAssertEqual(pos, ["-12", "300", "Calculator"])
        // And the coords still parse after the (pure) flag scan.
        XCTAssertEqual(Double(pos[0]), -12)
    }

    // MARK: drag-path interpolation geometry (PURE)

    func testInterpolateReturnsInteriorPointsOnly() {
        // steps=4 ⇒ 3 interior points at t = 1/4, 2/4, 3/4 (endpoints excluded).
        let pts = PixelPath.interpolate(start: CGPoint(x: 0, y: 0),
                                        end: CGPoint(x: 40, y: 80), steps: 4)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].x, 10, accuracy: 0.0001); XCTAssertEqual(pts[0].y, 20, accuracy: 0.0001)
        XCTAssertEqual(pts[1].x, 20, accuracy: 0.0001); XCTAssertEqual(pts[1].y, 40, accuracy: 0.0001)
        XCTAssertEqual(pts[2].x, 30, accuracy: 0.0001); XCTAssertEqual(pts[2].y, 60, accuracy: 0.0001)
    }

    func testInterpolateStepCountMatchesDefaultDragSteps() {
        // The live drag uses GhostHands.dragSteps; the interior count is steps-1.
        let pts = PixelPath.interpolate(start: CGPoint(x: 0, y: 0),
                                        end: CGPoint(x: 100, y: 0),
                                        steps: GhostHands.dragSteps)
        XCTAssertEqual(pts.count, GhostHands.dragSteps - 1)
    }

    func testInterpolateZeroOrOneStepHasNoInteriorPoints() {
        // A single jump (steps <= 1) yields no intermediate moves.
        XCTAssertEqual(PixelPath.interpolate(start: .zero, end: CGPoint(x: 9, y: 9), steps: 1).count, 0)
        XCTAssertEqual(PixelPath.interpolate(start: .zero, end: CGPoint(x: 9, y: 9), steps: 0).count, 0)
    }

    // MARK: PixelOutcome mode label (default invisible, visible is opt-in)

    func testOutcomeDefaultModeIsInvisible() {
        let o = PixelOutcome(app: "Calc", verb: "click-at", x: 10, y: 20,
                             dispatched: true, verified: false, observable: true,
                             changedFraction: 0.0)
        XCTAssertEqual(o.mode, .invisible)
    }

    func testOutcomeCarriesVisibleMode() {
        let o = PixelOutcome(app: "Calc", verb: "click-at", x: 10, y: 20,
                             dispatched: true, verified: true, observable: true,
                             changedFraction: 0.42, mode: .visible)
        XCTAssertEqual(o.mode, .visible)
    }
}
