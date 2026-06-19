import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE pieces behind the app-level eye and the dock-click fix:
/// `AppInfo.line` rendering and the control-role gate now admitting `AXDockItem`.
/// The live list (`GhostHands.apps()`) reads `NSWorkspace` and is exercised live,
/// never in a unit test.
final class AppsTests: XCTestCase {

    func testAppLineWithBundleAndFrontmost() {
        let a = AppInfo(name: "Cursor", bundleID: "com.todesktop.x", pid: 123, active: true)
        XCTAssertEqual(a.line, "Cursor (com.todesktop.x)  pid=123 [frontmost]")
    }

    func testAppLineWithoutBundleNotFrontmost() {
        let a = AppInfo(name: "Helper", bundleID: nil, pid: 7, active: false)
        XCTAssertEqual(a.line, "Helper  pid=7")
    }

    /// The dock-click fix: an `AXDockItem` is now an actionable control, so
    /// `click "<App>" Dock` treats the dock tile as pressable (it was excluded
    /// before — `find` saw it but `click` refused it).
    func testDockItemIsActionable() {
        let dockTile = ElementFacts(role: "AXDockItem", title: "Cursor", value: nil)
        XCTAssertTrue(Finder.isActionable(dockTile))
    }

    /// Guard the gate didn't go loose: a static-text node is still NOT actionable.
    func testStaticTextStillNotActionable() {
        let label = ElementFacts(role: "AXStaticText", title: "Cursor", value: nil)
        XCTAssertFalse(Finder.isActionable(label))
    }
}
