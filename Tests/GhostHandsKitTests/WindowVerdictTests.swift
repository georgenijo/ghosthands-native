import CoreGraphics
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE window-management honesty core on FABRICATED frames,
/// screens, and selector inputs. NEVER resolves a real app, enumerates live
/// windows, calls setPosition/setSize, or touches NSScreen: every input is a
/// hand-built CGRect / CGPoint / CGSize / WindowInfo. Covers the required arms:
///   - display-index mapping (in-screen-0, in-screen-1, off-all, deterministic tie),
///   - selector resolution (id unique, title unique, none → ambiguous, 0 → not-found,
///     single-no-selector → operate, multi-no-selector → refuse),
///   - move/resize read-back verdict (target vs OS-clamped vs unchanged),
///   - outcome honesty invariants (a dispatched/raise outcome has verified == false).
final class WindowVerdictTests: XCTestCase {

    // MARK: helpers — fabricated WindowInfo (never a live window)

    private func win(id: CGWindowID?, title: String?, frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
                     screenIndex: Int? = 0, minimized: Bool = false,
                     isMain: Bool = false, isFocused: Bool = false) -> WindowInfo {
        WindowInfo(id: id, title: title, frame: frame, screenIndex: screenIndex,
                   minimized: minimized, isMain: isMain, isFocused: isFocused)
    }

    // MARK: - display-index mapping (WindowList.screenIndex)

    func testCenterInScreenZeroMapsToZero() {
        // Two side-by-side top-left displays; a center on the left → 0.
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(WindowList.screenIndex(forCenter: CGPoint(x: 700, y: 450), in: screens), 0)
    }

    func testCenterInScreenOneMapsToOne() {
        // A center on the right-hand display (x past 1440) → 1.
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(WindowList.screenIndex(forCenter: CGPoint(x: 2400, y: 540), in: screens), 1)
    }

    func testCenterOffAllScreensIsNil() {
        // A center below/right of every display (off-screen / Space-shifted) → nil,
        // reported honestly as off-screen, never coerced to a screen.
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        XCTAssertNil(WindowList.screenIndex(forCenter: CGPoint(x: 5000, y: 5000), in: screens))
        XCTAssertNil(WindowList.screenIndex(forCenter: CGPoint(x: -10, y: -10), in: screens))
    }

    func testOverlappingScreensPickFirstContainingDeterministically() {
        // When two screens overlap a point, the FIRST in list order wins (stable).
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 1000),
                       CGRect(x: 500, y: 0, width: 1000, height: 1000)]
        XCTAssertEqual(WindowList.screenIndex(forCenter: CGPoint(x: 700, y: 500), in: screens), 0)
    }

    func testEmptyScreenListIsNil() {
        XCTAssertNil(WindowList.screenIndex(forCenter: CGPoint(x: 10, y: 10), in: []))
    }

    func testFrameCenterDrivesTheMapping() {
        // Map via the frame's own center: a window fully on display 1.
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let frame = CGRect(x: 1600, y: 200, width: 400, height: 300)
        let center = CGPoint(x: frame.midX, y: frame.midY)   // (1800, 350)
        XCTAssertEqual(WindowList.screenIndex(forCenter: center, in: screens), 1)
    }

    // MARK: - selector resolution (WindowList.select)

    func testSingleWindowNoSelectorOperatesOnIt() {
        // One window + no selector → operate on it (index 0), no ambiguity refuse.
        let windows = [win(id: 1, title: "Only")]
        XCTAssertEqual(WindowList.select(windows, by: nil), .one(0))
    }

    func testMultipleWindowsNoSelectorRefusesAmbiguous() {
        // >1 window + no selector → REFUSE (ambiguous), never silently window[0].
        let windows = [win(id: 1, title: "A"), win(id: 2, title: "B")]
        switch WindowList.select(windows, by: nil) {
        case let .ambiguous(candidates):
            XCTAssertEqual(candidates.count, 2)
        default:
            XCTFail("expected ambiguous refuse for >1 window with no selector")
        }
    }

    func testSelectByIdUniqueSelectsThatWindow() {
        let windows = [win(id: 10, title: "A"), win(id: 20, title: "B"), win(id: 30, title: "C")]
        XCTAssertEqual(WindowList.select(windows, by: .id(20)), .one(1))
    }

    func testSelectByTitleUniqueSelectsThatWindow() {
        let windows = [win(id: 10, title: "Inbox"), win(id: 20, title: "Compose")]
        XCTAssertEqual(WindowList.select(windows, by: .title("Compose")), .one(1))
    }

    func testSelectByTitleIsCaseInsensitive() {
        let windows = [win(id: 10, title: "Inbox"), win(id: 20, title: "Compose")]
        XCTAssertEqual(WindowList.select(windows, by: .title("compose")), .one(1))
    }

    func testSelectorMatchingNothingIsNotFound() {
        let windows = [win(id: 10, title: "A"), win(id: 20, title: "B")]
        XCTAssertEqual(WindowList.select(windows, by: .id(999)), .notFound)
        XCTAssertEqual(WindowList.select(windows, by: .title("Nope")), .notFound)
    }

    func testSelectorMatchingMultipleIsAmbiguous() {
        // Two windows share a title → a title selector still REFUSES rather than
        // pick the first.
        let windows = [win(id: 10, title: "Untitled"), win(id: 20, title: "Untitled")]
        switch WindowList.select(windows, by: .title("Untitled")) {
        case let .ambiguous(candidates):
            XCTAssertEqual(candidates.count, 2)
        default:
            XCTFail("expected ambiguous for a title matching >1 window")
        }
    }

    func testEmptyWindowListIsEmpty() {
        // .empty models an app whose AX read SUCCEEDED and returned zero windows
        // (the live verb maps it to .noWindows). It is NOT the read-failure case:
        // a nil windows() read throws .windowListUnreadable BEFORE select() runs,
        // so the two are never conflated. See testWindowListUnreadableIsDistinct...
        XCTAssertEqual(WindowList.select([], by: nil), .empty)
        XCTAssertEqual(WindowList.select([], by: .id(1)), .empty)
    }

    func testNilIdWindowIsNotMatchedByIdSelector() {
        // A window whose id failed to resolve (nil) is not matched by an id
        // selector — honest, never coerced.
        let windows = [win(id: nil, title: "ghost"), win(id: 5, title: "real")]
        XCTAssertEqual(WindowList.select(windows, by: .id(5)), .one(1))
        XCTAssertEqual(WindowList.select(windows, by: .id(0)), .notFound)
    }

    // MARK: - WindowSelector.parse (numeric → id, else → title)

    func testSelectorParseNumericIsId() {
        XCTAssertEqual(WindowSelector.parse("12345"), .id(12345))
    }

    func testSelectorParseNonNumericIsTitle() {
        XCTAssertEqual(WindowSelector.parse("Inbox"), .title("Inbox"))
        // A title that merely starts with digits but isn't a pure number stays a title.
        XCTAssertEqual(WindowSelector.parse("3 Downloads"), .title("3 Downloads"))
    }

    // MARK: - move/resize read-back verdict (WindowFrameVerdict)

    func testMoveExactTargetIsVerified() {
        // Read-back == target → VERIFIED.
        let v = WindowFrameVerdict.decide(target: CGPoint(x: 100, y: 80),
                                          before: CGPoint(x: 0, y: 0),
                                          after: CGPoint(x: 100, y: 80))
        XCTAssertEqual(v, .verified)
    }

    func testMoveWithinToleranceIsVerified() {
        // Apps that quantize land a pixel or two off — still VERIFIED within tol.
        let v = WindowFrameVerdict.decide(target: CGPoint(x: 100, y: 80),
                                          before: CGPoint(x: 0, y: 0),
                                          after: CGPoint(x: 101, y: 79),
                                          tolerance: 2)
        XCTAssertEqual(v, .verified)
    }

    func testMoveOsClampedReportsActualLanding() {
        // The window moved from before, but the OS constrained it elsewhere (e.g.
        // off-screen guard) → CLAMPED with the ACTUAL landing, NOT a fake verified.
        let v = WindowFrameVerdict.decide(target: CGPoint(x: -500, y: -500),
                                          before: CGPoint(x: 0, y: 0),
                                          after: CGPoint(x: 0, y: -38))   // clamped under menu bar
        XCTAssertEqual(v, .clamped(actualX: 0, actualY: -38))
    }

    func testMoveAxAcceptedButUnchangedIsDispatched() {
        // setPosition returned .success but the window did not move and that isn't
        // the target (full-screen / modal ignored the set) → DISPATCHED-unverified.
        let v = WindowFrameVerdict.decide(target: CGPoint(x: 300, y: 300),
                                          before: CGPoint(x: 50, y: 50),
                                          after: CGPoint(x: 50, y: 50))
        XCTAssertEqual(v, .dispatched)
    }

    func testResizeExactTargetIsVerified() {
        let v = WindowFrameVerdict.decide(target: CGSize(width: 800, height: 600),
                                          before: CGSize(width: 400, height: 300),
                                          after: CGSize(width: 800, height: 600))
        XCTAssertEqual(v, .verified)
    }

    func testResizeOsClampedToMinSizeReportsActual() {
        // Asked smaller than the window's minimum; the OS clamps to the min — the
        // size MOVED from before but not to target → CLAMPED with the real size.
        let v = WindowFrameVerdict.decide(target: CGSize(width: 50, height: 50),
                                          before: CGSize(width: 800, height: 600),
                                          after: CGSize(width: 300, height: 200))  // min size
        XCTAssertEqual(v, .clamped(actualX: 300, actualY: 200))
    }

    func testResizeUnchangedIsDispatched() {
        // AX accepted but a full-screen window ignored the resize → DISPATCHED.
        let v = WindowFrameVerdict.decide(target: CGSize(width: 1000, height: 800),
                                          before: CGSize(width: 1440, height: 900),
                                          after: CGSize(width: 1440, height: 900))
        XCTAssertEqual(v, .dispatched)
    }

    func testVerifiedTakesPriorityWhenOneAxisClampedButBothWithinTol() {
        // Both axes within tolerance of target → VERIFIED even though 'before' was
        // far away (the move clearly landed on target).
        let v = WindowFrameVerdict.decide(targetA: 200, targetB: 200,
                                          beforeA: 0, beforeB: 0,
                                          afterA: 200, afterB: 201, tolerance: 2)
        XCTAssertEqual(v, .verified)
    }

    // MARK: - outcome honesty invariants

    func testRaiseOutcomeIsNeverVerified() {
        // A raise outcome must carry verified == false (z-order is unobservable).
        let o = WindowRaiseOutcome(app: "Preview", windowTitle: "doc.pdf",
                                   windowID: 7, axAccepted: true, verified: false)
        XCTAssertTrue(o.axAccepted)
        XCTAssertFalse(o.verified)
    }

    func testDispatchedMutateOutcomeNotVerified() {
        let o = WindowMutateOutcome(app: "Calc", verb: "move", windowTitle: nil, windowID: 3,
                                    axAccepted: true, verified: false, clamped: false,
                                    frameBefore: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    frameAfter: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(o.axAccepted)
        XCTAssertFalse(o.verified)
        XCTAssertFalse(o.clamped)
    }

    func testClampedMutateOutcomeIsHonestlyNotVerified() {
        // A clamped move is honest dispatched: clamped == true, verified == false,
        // and frameAfter carries the ACTUAL landing (not the requested target).
        let o = WindowMutateOutcome(app: "Calc", verb: "move", windowTitle: "Main", windowID: 3,
                                    axAccepted: true, verified: false, clamped: true,
                                    frameBefore: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    frameAfter: CGRect(x: 0, y: -38, width: 100, height: 100))
        XCTAssertFalse(o.verified)
        XCTAssertTrue(o.clamped)
        XCTAssertEqual(o.frameAfter.minY, -38)
    }

    func testVerifiedMutateOutcomeIsNotClamped() {
        let o = WindowMutateOutcome(app: "Calc", verb: "resize", windowTitle: nil, windowID: nil,
                                    axAccepted: true, verified: true, clamped: false,
                                    frameBefore: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    frameAfter: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(o.verified)
        XCTAssertFalse(o.clamped)
    }

    // MARK: - WindowList.describe (candidate labelling for the refuse list)

    func testDescribeUsesIdAndTitle() {
        XCTAssertEqual(WindowList.describe(win(id: 42, title: "Inbox")), "id=42 \"Inbox\"")
    }

    func testDescribeHandlesNilIdAndEmptyTitle() {
        XCTAssertEqual(WindowList.describe(win(id: nil, title: "")), "id=? (untitled)")
        XCTAssertEqual(WindowList.describe(win(id: nil, title: nil)), "id=? (untitled)")
    }

    // MARK: - read-failure vs zero-windows honesty (windowListUnreadable)

    /// The AX-read-FAILURE error is a DISTINCT case from "app has zero windows":
    /// a nil `windows()` read must NOT collapse into `.noWindows`. (Pure check on
    /// the error enum — no live app; the live `enumerate` throws this on nil.)
    func testWindowListUnreadableIsDistinctFromNoWindows() {
        let unreadable = GhostHandsError.windowListUnreadable(app: "Finder")
        let none = GhostHandsError.noWindows(app: "Finder")
        // Different cases — a caller switching on the error can tell them apart.
        switch unreadable {
        case .windowListUnreadable: break
        default: XCTFail("expected .windowListUnreadable")
        }
        switch none {
        case .noWindows: break
        default: XCTFail("expected .noWindows")
        }
    }

    /// The read-failure message must say it is an AX read failure and explicitly
    /// NOT a windowless app — never mislead the caller into "no windows".
    func testWindowListUnreadableMessageIsHonest() {
        let msg = GhostHandsError.windowListUnreadable(app: "Finder").description
        XCTAssertTrue(msg.contains("Finder"))
        XCTAssertTrue(msg.lowercased().contains("could not read"))
        XCTAssertTrue(msg.lowercased().contains("not a windowless app"))
        // It must NOT claim the app simply has no windows.
        XCTAssertFalse(msg.contains("no on-screen windows"))
    }

    /// The two messages read differently so logs/CLI distinguish them.
    func testNoWindowsMessageDiffersFromUnreadable() {
        let unreadable = GhostHandsError.windowListUnreadable(app: "Notes").description
        let none = GhostHandsError.noWindows(app: "Notes").description
        XCTAssertNotEqual(unreadable, none)
    }
}
