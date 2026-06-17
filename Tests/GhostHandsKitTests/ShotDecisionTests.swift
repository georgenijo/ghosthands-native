import XCTest
@testable import GhostHandsKit

/// Hermetic — the pure `shot` refusal decision (a function of two booleans, no
/// capture). The honesty gate: NO Screen Recording → refuse BEFORE anything
/// else; permission present but no window → refuse; both → allow.
final class ShotDecisionTests: XCTestCase {
    func testNoPermissionRefusesEvenWithWindow() {
        XCTAssertEqual(Shot.decide(hasScreenRecording: false, hasWindow: true),
                       .refuseNoPermission)
    }

    func testNoPermissionRefusesWithoutWindow() {
        // Permission is checked FIRST — the message a user sees is about the grant.
        XCTAssertEqual(Shot.decide(hasScreenRecording: false, hasWindow: false),
                       .refuseNoPermission)
    }

    func testPermissionButNoWindowRefuses() {
        XCTAssertEqual(Shot.decide(hasScreenRecording: true, hasWindow: false),
                       .refuseNoWindow)
    }

    func testPermissionAndWindowAllows() {
        XCTAssertEqual(Shot.decide(hasScreenRecording: true, hasWindow: true),
                       .allow)
    }
}
