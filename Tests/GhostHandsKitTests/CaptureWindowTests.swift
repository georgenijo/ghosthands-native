import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE capture-window pick (OCR/shot robustness). Over fabricated
/// candidates; no live ScreenCaptureKit. The pick NEVER returns another app's
/// window and falls back to PID-matched selection when the AX bridge fails.
final class CaptureWindowTests: XCTestCase {

    private func cand(_ id: UInt32, pid: pid_t, area: Double = 1000, layer: Int = 0,
                      onScreen: Bool = true) -> CaptureCandidate {
        CaptureCandidate(windowID: id, pid: pid, area: area, layer: layer, onScreen: onScreen)
    }

    func testPrefersBridgedIdWhenItBelongsToTheApp() {
        let cs = [cand(10, pid: 7), cand(11, pid: 7)]
        XCTAssertEqual(CaptureWindowPick.choose(cs, pid: 7, preferred: 11), 11)
    }

    func testIgnoresBridgedIdFromAnotherApp() {
        // A preferred id owned by a DIFFERENT pid must NOT be used — never capture
        // another app's window. Fall back to the target app's own.
        let cs = [cand(10, pid: 7), cand(99, pid: 42)]
        XCTAssertEqual(CaptureWindowPick.choose(cs, pid: 7, preferred: 99), 10)
    }

    func testFallbackWhenBridgeFailed() {
        // preferred nil (AX→CG bridge returned nil) → PID fallback still finds the
        // app's window — the whole point (OCR worked even when the bridge fails).
        let cs = [cand(10, pid: 7), cand(20, pid: 7)]
        XCTAssertNotNil(CaptureWindowPick.choose(cs, pid: 7, preferred: nil))
    }

    func testRanksOnScreenThenNormalLayerThenArea() {
        let offscreen = cand(1, pid: 7, area: 9999, onScreen: false)
        let overlay = cand(2, pid: 7, area: 9999, layer: 25, onScreen: true)
        let small = cand(3, pid: 7, area: 100, layer: 0, onScreen: true)
        let main = cand(4, pid: 7, area: 5000, layer: 0, onScreen: true)
        // main: on-screen, layer 0, largest → wins over off-screen / overlay / small.
        XCTAssertEqual(CaptureWindowPick.choose([offscreen, overlay, small, main],
                                                pid: 7, preferred: nil), 4)
    }

    func testNoWindowForAppIsNil() {
        let cs = [cand(1, pid: 42), cand(2, pid: 99)]
        XCTAssertNil(CaptureWindowPick.choose(cs, pid: 7, preferred: nil))
        XCTAssertNil(CaptureWindowPick.choose([], pid: 7, preferred: 5))
    }
}
