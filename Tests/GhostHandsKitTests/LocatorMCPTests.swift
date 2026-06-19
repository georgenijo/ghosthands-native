import XCTest
@testable import GhostHandsKit

/// Hermetic — issue #5: `click`/`type`/`set_value` advertise the locator
/// disambiguators on the MCP surface (the CLI already wired them via parseLocator).
/// `type` is the special case: its required `text` arg is the text to TYPE, so it
/// must NOT also advertise a `--text` field-label locator (a duplicate key) — it
/// disambiguates by role/nth only.
final class LocatorMCPTests: XCTestCase {

    private func propNames(_ tool: String) -> [String] {
        (MCPTools.tool(named: tool)?.properties ?? []).map(\.name)
    }

    func testClickAdvertisesAllThreeLocators() {
        let p = propNames("click")
        XCTAssertTrue(p.contains("role"))
        XCTAssertTrue(p.contains("text"))
        XCTAssertTrue(p.contains("nth"))
    }

    func testSetValueAdvertisesAllThreeLocators() {
        let p = propNames("set_value")
        XCTAssertTrue(p.contains("role"))
        XCTAssertTrue(p.contains("text"))
        XCTAssertTrue(p.contains("nth"))
    }

    func testTypeAdvertisesRoleAndNthButNotADuplicateText() {
        let p = propNames("type")
        XCTAssertTrue(p.contains("role"))
        XCTAssertTrue(p.contains("nth"))
        // `text` appears EXACTLY once — the required text-to-type, never a second
        // locator key that would collide.
        XCTAssertEqual(p.filter { $0 == "text" }.count, 1)
    }
}
