import XCTest
@testable import GhostHandsKit

/// Hermetic — exercises the PURE locator refinement (`Locator.refine`) over
/// fabricated candidate lists, no live app driven (per the no-live-Calculator
/// rule). This is the unit-testable core of the opt-in disambiguators: --role /
/// --text filters, the --nth tie-break, the out-of-range REFUSE, and the
/// guarantee that the NO-FLAG path is byte-for-byte the existing
/// `NameMatch.resolve` (refuse-on-ambiguous intact).
final class LocatorTests: XCTestCase {
    private func f(_ title: String, role: String = "AXButton",
                   id: String? = nil, value: String? = nil,
                   description: String? = nil) -> ElementFacts {
        ElementFacts(role: role, title: title, identifier: id, value: value,
                     descriptionText: description, supportsPress: true)
    }

    // MARK: - --role filter

    func testRoleFilterNarrowsToSingle() {
        // Two "Save" controls of different roles; --role AXMenuButton keeps one.
        let cands = [f("Save", role: "AXButton"), f("Save", role: "AXMenuButton")]
        guard case .one(1) = Locator.refine(cands, query: "Save",
                                            role: "AXMenuButton", text: nil, nth: nil) else {
            return XCTFail("--role should narrow to the single AXMenuButton at index 1")
        }
    }

    func testRoleFilterIsCaseInsensitive() {
        let cands = [f("Go", role: "AXButton")]
        guard case .one(0) = Locator.refine(cands, query: "Go",
                                            role: "axbutton", text: nil, nth: nil) else {
            return XCTFail("--role match must be case-insensitive")
        }
    }

    func testRoleFilterNoSurvivorsIsNone() {
        let cands = [f("Save", role: "AXButton"), f("Save", role: "AXButton")]
        XCTAssertEqual(Locator.refine(cands, query: "Save",
                                      role: "AXSlider", text: nil, nth: nil), .none)
    }

    func testRoleFilterStillAmbiguousWithoutNth() {
        // Two distinct AXButtons survive the role filter; no --nth → STILL refuse.
        let cands = [f("Save As…", role: "AXButton"), f("Autosave", role: "AXButton")]
        guard case let .ambiguous(labels) = Locator.refine(cands, query: "save",
                                                           role: "AXButton", text: nil, nth: nil) else {
            return XCTFail("a role filter that leaves >1 distinct control must stay ambiguous")
        }
        XCTAssertEqual(labels.count, 2)
    }

    // MARK: - --text filter

    func testTextFilterNarrowsByLabelSubstring() {
        let cands = [f("Delete Inbox"), f("Delete Archive")]
        guard case .one(0) = Locator.refine(cands, query: "Delete",
                                            role: nil, text: "Inbox", nth: nil) else {
            return XCTFail("--text Inbox should keep only the first candidate")
        }
    }

    func testTextFilterIsCaseInsensitiveAndChecksValue() {
        let cands = [f("Field", value: "swiftlang"), f("Field", value: "python")]
        guard case .one(0) = Locator.refine(cands, query: "Field",
                                            role: nil, text: "SWIFT", nth: nil) else {
            return XCTFail("--text must match value case-insensitively")
        }
    }

    func testTextFilterNoSurvivorsIsNone() {
        let cands = [f("Open"), f("Close")]
        XCTAssertEqual(Locator.refine(cands, query: "Open",
                                      role: nil, text: "zzz", nth: nil), .none)
    }

    // MARK: - --nth pick

    func testNthPicksThatIndexInTreeOrder() {
        let cands = [f("Add"), f("Add"), f("Add")]
        // Distinct-by-construction? No — identityKey collides, but --nth bypasses
        // NameMatch.resolve entirely and pins the i-th SURVIVOR in tree order.
        guard case .one(1) = Locator.refine(cands, query: "Add",
                                            role: nil, text: nil, nth: 1) else {
            return XCTFail("--nth 1 must pick the 2nd candidate (index 1)")
        }
    }

    func testNthAfterFiltersIndexesSurvivorsNotOriginal() {
        // Role filter drops index 0 (a slider); --nth 0 then pins the FIRST
        // SURVIVOR, which is the original index 1 — proving --nth indexes the
        // filtered pool but the returned index maps back to the ORIGINAL array.
        let cands = [f("X", role: "AXSlider"), f("X", role: "AXButton"), f("X", role: "AXButton")]
        guard case .one(1) = Locator.refine(cands, query: "X",
                                            role: "AXButton", text: nil, nth: 0) else {
            return XCTFail("--nth 0 over the AXButton survivors must map back to original index 1")
        }
        guard case .one(2) = Locator.refine(cands, query: "X",
                                            role: "AXButton", text: nil, nth: 1) else {
            return XCTFail("--nth 1 over the AXButton survivors must map back to original index 2")
        }
    }

    func testNthZeroOnSingleMatch() {
        guard case .one(0) = Locator.refine([f("Only")], query: "Only",
                                            role: nil, text: nil, nth: 0) else {
            return XCTFail("--nth 0 on a single match is index 0")
        }
    }

    // MARK: - --nth out of range REFUSES (honesty gate)

    func testNthOutOfRangeRefuses() {
        let cands = [f("Add"), f("Add")]
        guard case let .indexOutOfRange(requested, count) = Locator.refine(
            cands, query: "Add", role: nil, text: nil, nth: 5) else {
            return XCTFail("--nth past the end must REFUSE, never clamp")
        }
        XCTAssertEqual(requested, 5)
        XCTAssertEqual(count, 2)
    }

    func testNthNegativeRefuses() {
        let cands = [f("Add"), f("Add")]
        guard case .indexOutOfRange(requested: -1, count: 2) = Locator.refine(
            cands, query: "Add", role: nil, text: nil, nth: -1) else {
            return XCTFail("a negative --nth must REFUSE")
        }
    }

    func testNthOutOfRangeAfterFilterCountsSurvivors() {
        // Two candidates, only ONE survives the role filter; --nth 1 is then OOR
        // with count == 1 (the survivor count, not the original 2).
        let cands = [f("X", role: "AXButton"), f("X", role: "AXSlider")]
        guard case .indexOutOfRange(requested: 1, count: 1) = Locator.refine(
            cands, query: "X", role: "AXButton", text: nil, nth: 1) else {
            return XCTFail("--nth out of range must count SURVIVORS, not the raw candidates")
        }
    }

    // MARK: - empty input

    func testEmptyCandidatesIsNone() {
        XCTAssertEqual(Locator.refine([], query: "x", role: "AXButton", text: nil, nth: nil), .none)
        XCTAssertEqual(Locator.refine([], query: "x", role: nil, text: nil, nth: 0), .none)
    }

    // MARK: - no-flag fall-through is IDENTICAL to NameMatch.resolve

    func testNoFlagFallsThroughToAmbiguous() {
        // No flags at all → refine must defer to NameMatch.resolve, which refuses
        // two distinct controls exactly as the pre-flag path does.
        let cands = [f("Save", role: "AXButton"), f("Save", role: "AXMenuButton")]
        guard case .ambiguous = Locator.refine(cands, query: "Save",
                                               role: nil, text: nil, nth: nil) else {
            return XCTFail("no-flag refine must refuse-on-ambiguous like NameMatch.resolve")
        }
    }

    func testNoFlagPathMatchesNameMatchResolveExactly() {
        // Property check: across a spread of fabricated candidate lists, the
        // no-flag refine result is the SAME verdict (unique↔one / ambiguous /
        // none) as calling NameMatch.resolve directly — the byte-for-byte
        // guarantee that the no-flag path is the pre-flag path.
        let lists: [[ElementFacts]] = [
            [],
            [f("Save")],
            [f("Save"), f("Save")],                                  // duplicate render → unique
            [f("Save", role: "AXButton"), f("Save", role: "AXMenuButton")], // distinct → ambiguous
            [f("Save As…"), f("Save")],                              // exact wins → unique(1)
            [f("Save As…"), f("Autosave")],                          // substring-only → ambiguous
        ]
        for cands in lists {
            let refined = Locator.refine(cands, query: "Save", role: nil, text: nil, nth: nil)
            switch NameMatch.resolve(cands, query: "Save") {
            case let .unique(i):
                XCTAssertEqual(refined, .one(i), "no-flag refine must equal NameMatch.unique(\(i))")
            case let .ambiguous(labels):
                XCTAssertEqual(refined, .ambiguous(labels),
                               "no-flag refine must equal NameMatch.ambiguous")
            case .none:
                XCTAssertEqual(refined, .none, "no-flag refine must equal NameMatch.none")
            }
        }
    }

    // MARK: - combined filters

    func testRoleAndTextTogetherThenNth() {
        // Mixed roles + labels; --role AXButton AND --text "delete" leaves two,
        // then --nth 1 pins the second survivor.
        let cands = [
            f("delete inbox", role: "AXMenuItem"),  // dropped by role
            f("delete inbox", role: "AXButton"),    // survivor 0 → orig 1
            f("keep inbox", role: "AXButton"),      // dropped by text
            f("delete archive", role: "AXButton"),  // survivor 1 → orig 3
        ]
        guard case .one(3) = Locator.refine(cands, query: "delete",
                                            role: "AXButton", text: "delete", nth: 1) else {
            return XCTFail("--role + --text + --nth 1 must pin original index 3")
        }
    }
}
