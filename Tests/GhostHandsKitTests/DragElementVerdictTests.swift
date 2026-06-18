import CoreGraphics
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE element-to-element drag core on FABRICATED data. NEVER
/// drives a live app, posts a CGEvent, or reads an AX tree: every input is a
/// hand-built `CGRect` / `CGPoint` / read-back enum.
///
/// Two pure pieces are under test:
///   1. `DragGeometry` — the from/to CENTER computation from two frames.
///   2. `DragVerdict`  — the witnessed-move/vanish → VERIFIED, else DISPATCHED
///                       honesty decider (a pixel drag has no self-signal, so the
///                       ONLY honest VERIFIED is an observed move/vanish of the
///                       FROM-element).
/// Plus the candidate-gate reuse and the DragElementOutcome honesty invariants.
final class DragElementVerdictTests: XCTestCase {

    // MARK: DragGeometry — center computation (the from/to aim points)

    func testCenterOfFrameIsMidPoint() {
        // A 100×60 frame at (10,20) centers at (60,50).
        let c = DragGeometry.center(of: CGRect(x: 10, y: 20, width: 100, height: 60))
        XCTAssertEqual(c.x, 60, accuracy: 0.0001)
        XCTAssertEqual(c.y, 50, accuracy: 0.0001)
    }

    func testCenterOfZeroSizeFrameIsItsOrigin() {
        // A degenerate (0×0) frame centers exactly on its origin — no NaN, no crash.
        let c = DragGeometry.center(of: CGRect(x: 42, y: 7, width: 0, height: 0))
        XCTAssertEqual(c.x, 42, accuracy: 0.0001)
        XCTAssertEqual(c.y, 7, accuracy: 0.0001)
    }

    func testCentersReturnsBothEndpoints() {
        // The from-center (press point) and to-center (drop point) in one call.
        let from = CGRect(x: 0, y: 0, width: 40, height: 40)        // center (20,20)
        let to = CGRect(x: 200, y: 100, width: 80, height: 20)      // center (240,110)
        let (f, t) = DragGeometry.centers(from: from, to: to)
        XCTAssertEqual(f.x, 20, accuracy: 0.0001)
        XCTAssertEqual(f.y, 20, accuracy: 0.0001)
        XCTAssertEqual(t.x, 240, accuracy: 0.0001)
        XCTAssertEqual(t.y, 110, accuracy: 0.0001)
    }

    func testCentersAreIndependentOfOrder() {
        // centers(from:to:) must aim from-from and to-to, never swap them.
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)          // (5,5)
        let b = CGRect(x: 90, y: 90, width: 10, height: 10)        // (95,95)
        let (f, t) = DragGeometry.centers(from: a, to: b)
        XCTAssertEqual(f, DragGeometry.center(of: a))
        XCTAssertEqual(t, DragGeometry.center(of: b))
    }

    // MARK: DragVerdict — the VERIFIED arm (observed move)

    func testFromElementMovedFarIsVerified() {
        // The from-element re-resolved at a center well past the move floor — an
        // observed relocation ⇒ VERIFIED, quoting before → after.
        guard case let .verified(evidence) = DragVerdict.decide(
            dispatched: true, fromBefore: CGPoint(x: 120, y: 80),
            readback: .present(center: CGPoint(x: 300, y: 80))) else {
            return XCTFail("a moved from-element must verify the drag")
        }
        XCTAssertTrue(evidence.contains("moved"))
        XCTAssertTrue(evidence.contains("(120,80)"))
        XCTAssertTrue(evidence.contains("(300,80)"))
    }

    func testFromElementMovedExactlyAtFloorIsVerified() {
        // The floor is INCLUSIVE: a displacement exactly equal to the floor counts
        // as a real move (>=), so a drag that nudges precisely the floor verifies.
        let floor = DragVerdict.moveFloor
        guard case .verified = DragVerdict.decide(
            dispatched: true, fromBefore: CGPoint(x: 0, y: 0),
            readback: .present(center: CGPoint(x: floor, y: 0))) else {
            return XCTFail("a displacement at the floor must verify")
        }
    }

    func testFromElementVanishedIsVerified() {
        // The drag consumed/relocated the from-element out of the matchable set —
        // an observed disappearance is honest evidence ⇒ VERIFIED.
        guard case let .verified(evidence) = DragVerdict.decide(
            dispatched: true, fromBefore: CGPoint(x: 50, y: 50),
            readback: .vanished) else {
            return XCTFail("a vanished from-element must verify the drag")
        }
        XCTAssertTrue(evidence.contains("(gone)"))
        XCTAssertTrue(evidence.contains("no longer present"))
    }

    // MARK: DragVerdict — the DISPATCHED arm (honest under-claim)

    func testFromElementUnmovedIsDispatched() {
        // The from-element is still sitting at (≈) its original center — the events
        // were sent but nothing observably moved ⇒ DISPATCHED, never a fake success.
        XCTAssertEqual(
            DragVerdict.decide(dispatched: true, fromBefore: CGPoint(x: 100, y: 100),
                               readback: .present(center: CGPoint(x: 100, y: 100))),
            .dispatched)
    }

    func testSubFloorJitterIsDispatched() {
        // A displacement BELOW the floor is treated as AX jitter / a 1-point repaint
        // nudge, NOT a drag effect ⇒ DISPATCHED (the floor's whole reason to exist).
        let belowFloor = DragVerdict.moveFloor - 0.5
        XCTAssertEqual(
            DragVerdict.decide(dispatched: true, fromBefore: CGPoint(x: 10, y: 10),
                               readback: .present(center: CGPoint(x: 10 + belowFloor, y: 10))),
            .dispatched)
    }

    func testFrameUnreadableOnReadbackIsDispatched() {
        // The from-element re-resolved but AX exposed no frame on the read-back — we
        // cannot measure a move, so this is an honest under-claim, NOT evidence.
        XCTAssertEqual(
            DragVerdict.decide(dispatched: true, fromBefore: CGPoint(x: 0, y: 0),
                               readback: .frameUnreadable),
            .dispatched)
    }

    func testNotDispatchedIsDispatchedNeverVerified() {
        // Defensive: a non-dispatched input can never be VERIFIED even if the
        // read-back claims a huge move (the live verb always posts before deciding).
        XCTAssertEqual(
            DragVerdict.decide(dispatched: false, fromBefore: CGPoint(x: 0, y: 0),
                               readback: .present(center: CGPoint(x: 999, y: 999))),
            .dispatched)
        XCTAssertEqual(
            DragVerdict.decide(dispatched: false, fromBefore: CGPoint(x: 0, y: 0),
                               readback: .vanished),
            .dispatched)
    }

    func testDiagonalMoveBelowFloorIsDispatched() {
        // The move test is EUCLIDEAN distance, not per-axis: a (3,3) shift is
        // dist ≈ 4.24, ABOVE a 4.0 floor (verifies); a (2,2) shift is ≈ 2.83
        // (dispatched). Confirm the distance math, not an axis-wise compare.
        // (2,2) ≈ 2.83 < 4.0 → dispatched
        XCTAssertEqual(
            DragVerdict.decide(dispatched: true, fromBefore: .zero,
                               readback: .present(center: CGPoint(x: 2, y: 2))),
            .dispatched)
        // (3,3) ≈ 4.24 ≥ 4.0 → verified
        guard case .verified = DragVerdict.decide(
            dispatched: true, fromBefore: .zero,
            readback: .present(center: CGPoint(x: 3, y: 3))) else {
            return XCTFail("a diagonal move past the floor must verify")
        }
    }

    // MARK: candidate gate — reuses Finder.isOpenable (rows/cells/files/controls)

    func testDragEndpointGateAcceptsRowsAndFiles() {
        // Drag sources/targets are commonly rows, cells, and file entries — the
        // openable gate (reused, not re-rolled) accepts them.
        for role in ["AXRow", "AXCell", "AXTextField", "AXOutline", "AXList"] {
            XCTAssertTrue(Finder.isOpenable(ElementFacts(role: role)),
                          "\(role) should be a valid drag endpoint")
        }
    }

    func testDragEndpointGateAcceptsControls() {
        // A pushable control (e.g. a draggable slider thumb exposed as a button)
        // also qualifies via the actionable arm of the openable gate.
        let f = ElementFacts(role: "AXButton", supportsPress: true,
                             supportedActions: ["AXPress"])
        XCTAssertTrue(Finder.isOpenable(f))
    }

    // MARK: DragElementOutcome honesty invariants (dispatched != verified)

    func testDispatchedOutcomeNotVerified() {
        // Events sent but no observed move: dispatched true, verified false, no evidence.
        let o = DragElementOutcome(app: "Preview", from: "page 1", to: "page 3",
                                   fromX: 100, fromY: 200, toX: 100, toY: 600,
                                   dispatched: true, verified: false, evidence: nil)
        XCTAssertTrue(o.dispatched)
        XCTAssertFalse(o.verified)
        XCTAssertNil(o.evidence)
    }

    func testVerifiedOutcomeCarriesEvidence() {
        let o = DragElementOutcome(app: "Finder", from: "a.png", to: "Photos",
                                   fromX: 50, fromY: 50, toX: 400, toY: 50,
                                   dispatched: true, verified: true,
                                   evidence: "from-element moved (50,50) → (400,50)")
        XCTAssertTrue(o.verified)
        XCTAssertEqual(o.evidence, "from-element moved (50,50) → (400,50)")
    }

    func testOutcomeDefaultsToInvisibleMode() {
        // The default delivery mode is invisible — the labelled --visible HID path
        // is opt-in, mirroring the pixel-click contract.
        let o = DragElementOutcome(app: "Finder", from: "a", to: "b",
                                   fromX: 0, fromY: 0, toX: 1, toY: 1,
                                   dispatched: true, verified: false, evidence: nil)
        XCTAssertEqual(o.mode, .invisible)
    }

    func testOutcomeCarriesVisibleMode() {
        let o = DragElementOutcome(app: "Finder", from: "a", to: "b",
                                   fromX: 0, fromY: 0, toX: 1, toY: 1,
                                   dispatched: true, verified: false, evidence: nil,
                                   mode: .visible)
        XCTAssertEqual(o.mode, .visible)
    }

    // MARK: error reuse — frame-less endpoint refuse (the honest one-liner)

    func testNoElementFrameErrorMentionsTheEndpoint() {
        // A frame-less endpoint reuses .noElementFrame (the same refuse the pixel
        // right-click fallback raises) — naming the endpoint so the refuse is honest.
        let msg = "\(GhostHandsError.noElementFrame(name: "icon.png"))"
        XCTAssertTrue(msg.contains("icon.png"))
        XCTAssertTrue(msg.contains("refusing"))
    }
}
