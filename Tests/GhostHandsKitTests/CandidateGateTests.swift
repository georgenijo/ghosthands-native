import XCTest
@testable import GhostHandsKit

/// Hermetic — the per-verb candidate gates (which roles count as a target for
/// type / set-value / doubleclick) and the secure-field + action-support facts.
/// Pure over fabricated `ElementFacts`, no live app. These prevent the
/// wrong-target / label-as-field class of bug: only the actionable/settable
/// control is a candidate, never the static label that merely shares its name.
final class CandidateGateTests: XCTestCase {
    private func f(role: String?, subrole: String? = nil, press: Bool = false,
                   actions: [String] = []) -> ElementFacts {
        ElementFacts(role: role, subrole: subrole, supportsPress: press,
                     supportedActions: actions)
    }

    // MARK: isTextEntry (type's candidate set)

    func testTextEntryAcceptsTextRoles() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(Finder.isTextEntry(f(role: role)), "\(role) is a text-entry candidate")
        }
    }

    func testTextEntryRejectsLabelsAndButtons() {
        // A static label that shares the field's title must NOT be a `type`
        // candidate — only the field is, so it is the unique winner.
        XCTAssertFalse(Finder.isTextEntry(f(role: "AXStaticText")))
        XCTAssertFalse(Finder.isTextEntry(f(role: "AXButton", press: true)))
    }

    // MARK: isSettable (set-value's candidate set)

    func testSettableAcceptsControlsAndTextEntry() {
        XCTAssertTrue(Finder.isSettable(f(role: "AXCheckBox")))
        XCTAssertTrue(Finder.isSettable(f(role: "AXSlider")))
        XCTAssertTrue(Finder.isSettable(f(role: "AXPopUpButton")))
        XCTAssertTrue(Finder.isSettable(f(role: "AXTextField")))      // via text-entry
        XCTAssertTrue(Finder.isSettable(f(role: "AXButton", press: true)))
    }

    func testSettableRejectsStaticText() {
        XCTAssertFalse(Finder.isSettable(f(role: "AXStaticText")))
        XCTAssertFalse(Finder.isSettable(f(role: "AXImage")))
    }

    // MARK: isOpenable (doubleclick's candidate set)

    func testOpenableAcceptsRowsCellsAndAXOpenAdvertisers() {
        XCTAssertTrue(Finder.isOpenable(f(role: "AXRow")))
        XCTAssertTrue(Finder.isOpenable(f(role: "AXCell")))
        // An NSOpenPanel file row: an AXTextField advertising AXOpen but no AXPress.
        XCTAssertTrue(Finder.isOpenable(f(role: "AXTextField", actions: ["AXOpen"])))
        XCTAssertTrue(Finder.isOpenable(f(role: "AXButton", press: true)))
    }

    func testOpenableRejectsPlainStaticText() {
        XCTAssertFalse(Finder.isOpenable(f(role: "AXStaticText")))
    }

    // MARK: read-back gate must match the resolve gate (the doubleclick honesty trap)

    /// The doubleclick false-success regression: a bare AXRow/AXCell/AXOutline/
    /// AXList is RESOLVED by `isOpenable`, but `isSettable` (the gate `act` uses,
    /// and the gate `performAndVerify` formerly HARDCODED for every verb's
    /// read-back) REJECTS those roles. With a narrower read-back gate, the still-
    /// present row can never be re-found → it reads `.absent` → `.goneConfirmed` →
    /// ClickVerdict fabricates VERIFIED "no longer present". The honest contract
    /// requires the read-back to use the SAME gate as resolve, so the row reads
    /// back `.present` and the verdict is an honest DISPATCHED. These assertions
    /// pin the gate asymmetry that makes threading the verb's gate mandatory.
    func testOpenableAdmitsRolesThatSettableRejects() {
        for role in ["AXRow", "AXCell", "AXOutline", "AXList"] {
            XCTAssertTrue(Finder.isOpenable(f(role: role)),
                          "\(role) is a doubleclick (isOpenable) candidate")
            XCTAssertFalse(Finder.isSettable(f(role: role)),
                           "\(role) is NOT settable — a read-back hardcoding isSettable would lose it")
        }
    }

    /// A row resolved for doubleclick must remain re-findable by the SAME gate.
    /// `isOpenable` accepts a bare AXRow (no AXPress, no AXOpen, no value), so the
    /// read-back gate (threaded from resolve) can re-find it on a fresh tree —
    /// the precondition for the verdict to read `.present` instead of a false
    /// `.goneConfirmed`.
    func testOpenableReadbackGateReadmitsResolvedRow() {
        let bareRow = f(role: "AXRow")
        // Resolve gate accepts it.
        XCTAssertTrue(Finder.isOpenable(bareRow))
        // The read-back, when threaded with the SAME (isOpenable) gate, re-admits
        // it — so a still-present row is observable on read-back, not "gone".
        let readbackGate: (ElementFacts) -> Bool = Finder.isOpenable
        XCTAssertTrue(readbackGate(bareRow),
                      "read-back gate threaded from resolve must re-admit the resolved row")
    }

    // MARK: secure-field gate (the type honesty refuse)

    func testSecureTextFieldDetected() {
        let secure = f(role: "AXTextField", subrole: "AXSecureTextField")
        XCTAssertTrue(secure.isSecureTextField)
    }

    func testPlainTextFieldIsNotSecure() {
        XCTAssertFalse(f(role: "AXTextField").isSecureTextField)
        XCTAssertFalse(f(role: "AXTextField", subrole: "AXSearchField").isSecureTextField)
    }

    // MARK: action-support facts (the act pre-check)

    func testSupportsReflectsAdvertisedActions() {
        let popup = f(role: "AXPopUpButton", actions: ["AXShowMenu", "AXPick"])
        XCTAssertTrue(popup.supports("AXShowMenu"))
        XCTAssertTrue(popup.supports("AXPick"))
        XCTAssertFalse(popup.supports("AXIncrement"))    // act would REFUSE this early
    }

    func testSupportsOpenConvenience() {
        XCTAssertTrue(f(role: "AXRow", actions: ["AXOpen"]).supportsOpen)
        XCTAssertFalse(f(role: "AXButton", actions: ["AXPress"]).supportsOpen)
    }
}
