import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE pieces of the visual overlay: the AX→Cocoa coordinate flip
/// and the env gate. The actual panel draw (`flash`) is AppKit/screen-bound and is
/// exercised live, never in a unit test.
final class HighlightTests: XCTestCase {

    /// AX (top-left origin, y down) → Cocoa (bottom-left origin, y up) mirrors y
    /// about the primary screen height; x/width/height are unchanged.
    func testCocoaRectFlipsYAboutPrimaryHeight() {
        let ax = CGRect(x: 100, y: 50, width: 200, height: 80)
        let cocoa = Highlight.cocoaRect(forAX: ax, primaryHeight: 1440)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 1440 - 50 - 80, width: 200, height: 80))
    }

    /// A rect flush to the top of the screen maps to the top of Cocoa space
    /// (cocoaY = primaryHeight - height), never a negative or fabricated origin.
    func testCocoaRectTopOfScreen() {
        let ax = CGRect(x: 0, y: 0, width: 50, height: 30)
        let cocoa = Highlight.cocoaRect(forAX: ax, primaryHeight: 1000)
        XCTAssertEqual(cocoa.origin.y, 970)
    }

    /// The env gate is OFF unless explicitly set to a truthy value.
    func testIsEnabledEnvGate() {
        let key = "GHOSTHANDS_HIGHLIGHT"
        let saved = ProcessInfo.processInfo.environment[key]
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }

        unsetenv(key)
        XCTAssertFalse(Highlight.isEnabled)
        setenv(key, "1", 1)
        XCTAssertTrue(Highlight.isEnabled)
        setenv(key, "true", 1)
        XCTAssertTrue(Highlight.isEnabled)
        setenv(key, "0", 1)
        XCTAssertFalse(Highlight.isEnabled)
    }
}
