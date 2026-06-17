import XCTest
@testable import GhostHandsKit

/// Hermetic — exercises the pure name-resolution scoring with fabricated
/// facts, no live app driven (per the no-live-Calculator rule).
final class NameMatchTests: XCTestCase {
    private func facts(title: String? = nil, identifier: String? = nil,
                       value: String? = nil, descriptionText: String? = nil,
                       press: Bool = false, enabled: Bool? = nil) -> ElementFacts {
        ElementFacts(title: title, identifier: identifier, value: value,
                     roleDescription: nil, descriptionText: descriptionText,
                     supportsPress: press, enabled: enabled)
    }

    func testExactTitleBeatsPartial() {
        let exact = facts(title: "Save")
        let partial = facts(title: "Save As…")
        XCTAssertGreaterThan(NameMatch.score(exact, query: "Save"),
                             NameMatch.score(partial, query: "Save"))
    }

    func testIdentifierExactScoresHigh() {
        let f = facts(identifier: "save-btn")
        XCTAssertTrue(NameMatch.matches(f, query: "save-btn"))
        XCTAssertGreaterThanOrEqual(NameMatch.score(f, query: "save-btn"), 400)
    }

    func testCaseInsensitiveMatch() {
        XCTAssertTrue(NameMatch.matches(facts(title: "New Folder"), query: "new folder"))
    }

    func testPressableAndEnabledBreakTie() {
        let plain = facts(title: "Go")
        let better = facts(title: "Go", press: true, enabled: true)
        XCTAssertGreaterThan(NameMatch.score(better, query: "Go"),
                             NameMatch.score(plain, query: "Go"))
    }

    func testValueAndDescriptionAlsoMatch() {
        XCTAssertTrue(NameMatch.matches(facts(value: "42"), query: "42"))
        XCTAssertTrue(NameMatch.matches(facts(descriptionText: "Close window"), query: "close"))
    }

    func testNoMatchIsFalseAndLowScore() {
        let f = facts(title: "Cancel")
        XCTAssertFalse(NameMatch.matches(f, query: "Submit"))
        XCTAssertEqual(NameMatch.score(f, query: "Submit"), 0)
    }
}
