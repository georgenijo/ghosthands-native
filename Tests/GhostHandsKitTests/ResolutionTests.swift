import XCTest
@testable import GhostHandsKit

/// Hermetic — the pure resolution that decides act / refuse / ambiguous, with
/// fabricated facts. This is where wrong-target and silent-ambiguity bugs are
/// caught without driving a live app.
final class ResolutionTests: XCTestCase {
    private func f(_ title: String, role: String = "AXButton",
                   id: String? = nil, value: String? = nil) -> ElementFacts {
        ElementFacts(role: role, title: title, identifier: id, value: value,
                     supportsPress: true)
    }

    func testNoneOnEmpty() {
        XCTAssertEqual(NameMatch.resolve([], query: "x"), .none)
    }

    func testUniqueSingle() {
        guard case .unique(0) = NameMatch.resolve([f("Save")], query: "Save") else {
            return XCTFail("single exact match should be unique(0)")
        }
    }

    func testDuplicateRenderCollapsesToUnique() {
        // Same control rendered in two AXWindow subtrees → one logical match.
        guard case .unique = NameMatch.resolve([f("Save"), f("Save")], query: "Save") else {
            return XCTFail("duplicate render should collapse to unique")
        }
    }

    func testTwoDistinctControlsAreAmbiguous() {
        let cands = [f("Save", role: "AXButton"), f("Save", role: "AXMenuButton")]
        guard case let .ambiguous(labels) = NameMatch.resolve(cands, query: "Save") else {
            return XCTFail("two distinct controls must refuse as ambiguous")
        }
        XCTAssertEqual(labels.count, 2)
    }

    func testExactPreferredOverSubstring() {
        // Both contain "Save"; only the second is an exact whole-string match.
        let cands = [f("Save As…"), f("Save")]
        guard case .unique(1) = NameMatch.resolve(cands, query: "Save") else {
            return XCTFail("exact match must win over substring")
        }
    }

    func testSubstringOnlyMultipleIsAmbiguous() {
        // Neither is exact; two distinct substring hits → refuse, don't guess.
        let cands = [f("Save As…"), f("Autosave")]
        guard case .ambiguous = NameMatch.resolve(cands, query: "save") else {
            return XCTFail("multiple distinct substring hits must be ambiguous")
        }
    }
}
