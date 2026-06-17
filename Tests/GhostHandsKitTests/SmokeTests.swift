import XCTest
@testable import GhostHandsKit

final class SmokeTests: XCTestCase {
    func testVersionPresent() {
        XCTAssertFalse(GhostHands.version.isEmpty)
    }
}
