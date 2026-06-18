import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE `dialog` core over FABRICATED `SnapshotNode` subtrees and
/// fabricated dismiss read-backs. NEVER resolves a real app, walks a live AX
/// tree, or presses anything: every input is a hand-built node forest / readback
/// enum. Covers the required arms:
///   - detection (AXSheet by role, AXDialog/AXSystemDialog by subrole, plain
///     window NOT a dialog, no-dialog → nil, frontmost wins),
///   - extraction (title, message static-text lines, button names, disabled flag,
///     dedup, title excluded from messages, nested dialog not pulled in),
///   - the dismiss verdict (gone → verified, still-present → dispatched,
///     not-observable/AX-read-failure → dispatched, never a fabricated verified),
///   - outcome honesty invariants (a dispatched outcome has verified == false).
final class DialogVerdictTests: XCTestCase {

    // MARK: helpers — fabricated SnapshotNode (never a live element)

    private func node(_ role: String, subrole: String? = nil, title: String? = nil,
                      value: String? = nil, desc: String? = nil, enabled: Bool? = nil,
                      actions: [String] = [], depth: Int = 0,
                      children: [SnapshotNode] = []) -> SnapshotNode {
        SnapshotNode(
            facts: ElementFacts(role: role, subrole: subrole, title: title,
                                value: value, descriptionText: desc,
                                supportsPress: actions.contains("AXPress"),
                                enabled: enabled, supportedActions: actions),
            depth: depth, children: children)
    }

    /// A button node (AXButton + AXPress).
    private func button(_ name: String, enabled: Bool = true, depth: Int = 2) -> SnapshotNode {
        node("AXButton", title: name, enabled: enabled, actions: ["AXPress"], depth: depth)
    }

    /// A typical save-sheet: a host window containing an AXSheet with a message +
    /// three buttons (Save / Don't Save / Cancel).
    private func saveSheetForest() -> [SnapshotNode] {
        [node("AXWindow", subrole: "AXStandardWindow", title: "Untitled", depth: 0, children: [
            node("AXButton", title: "Close", actions: ["AXPress"], depth: 1),  // host-window button, NOT in the sheet
            node("AXSheet", title: "Save changes?", depth: 1, children: [
                node("AXStaticText", value: "Do you want to save the changes you made?", depth: 2),
                button("Save", depth: 2),
                button("Don't Save", depth: 2),
                button("Cancel", depth: 2),
            ]),
        ])]
    }

    // MARK: - detection (isDialog)

    func testSheetRoleIsDialog() {
        XCTAssertTrue(DialogScan.isDialog(ElementFacts(role: "AXSheet")))
    }

    func testDialogSubroleIsDialog() {
        XCTAssertTrue(DialogScan.isDialog(ElementFacts(role: "AXWindow", subrole: "AXDialog")))
    }

    func testSystemDialogSubroleIsDialog() {
        XCTAssertTrue(DialogScan.isDialog(ElementFacts(role: "AXWindow", subrole: "AXSystemDialog")))
    }

    func testStandardWindowIsNotDialog() {
        // An ordinary document window must NEVER read as a modal — else `dialog`
        // would "detect" every app with an open window.
        XCTAssertFalse(DialogScan.isDialog(ElementFacts(role: "AXWindow", subrole: "AXStandardWindow")))
        XCTAssertFalse(DialogScan.isDialog(ElementFacts(role: "AXButton", title: "OK")))
    }

    // MARK: - detect (over a forest)

    func testDetectFindsSheet() {
        guard let d = DialogScan.detect(in: saveSheetForest()) else {
            return XCTFail("a save sheet must be detected")
        }
        XCTAssertEqual(d.title, "Save changes?")
        XCTAssertEqual(d.buttons.map(\.name), ["Save", "Don't Save", "Cancel"])
        XCTAssertEqual(d.messageLines, ["Do you want to save the changes you made?"])
    }

    func testDetectFindsDialogSubroleWindow() {
        // A modal alert exposed as an AXWindow with subrole AXDialog at top level.
        let forest = [node("AXWindow", subrole: "AXDialog", title: "Quit?", depth: 0, children: [
            node("AXStaticText", value: "Are you sure?", depth: 1),
            button("Quit", depth: 1),
            button("Cancel", depth: 1),
        ])]
        guard let d = DialogScan.detect(in: forest) else {
            return XCTFail("a subrole-AXDialog window must be detected")
        }
        XCTAssertEqual(d.title, "Quit?")
        XCTAssertEqual(d.buttons.map(\.name), ["Quit", "Cancel"])
    }

    func testNoDialogReturnsNil() {
        // A plain window with controls but no modal → nil (the live verb REFUSES).
        let forest = [node("AXWindow", subrole: "AXStandardWindow", title: "Doc", depth: 0, children: [
            node("AXButton", title: "Save", actions: ["AXPress"], depth: 1),
            node("AXStaticText", value: "hello", depth: 1),
        ])]
        XCTAssertNil(DialogScan.detect(in: forest))
    }

    func testEmptyForestIsNil() {
        XCTAssertNil(DialogScan.detect(in: []))
    }

    func testFrontmostDialogWinsAcrossWindows() {
        // Two windows each carry a sheet; the FIRST in forest order (AX front) is
        // the one reported — never the second.
        let forest = [
            node("AXWindow", title: "W1", depth: 0, children: [
                node("AXSheet", title: "First", depth: 1, children: [button("OK", depth: 2)]),
            ]),
            node("AXWindow", title: "W2", depth: 0, children: [
                node("AXSheet", title: "Second", depth: 1, children: [button("OK", depth: 2)]),
            ]),
        ]
        XCTAssertEqual(DialogScan.detect(in: forest)?.title, "First")
    }

    // MARK: - extraction details

    func testButtonNameFallsBackToDescription() {
        // A button with no title but an AXDescription label (a common close/help
        // glyph button) still surfaces by its description.
        let forest = [node("AXSheet", title: "T", depth: 0, children: [
            node("AXButton", desc: "Help", actions: ["AXPress"], depth: 1),
        ])]
        XCTAssertEqual(DialogScan.detect(in: forest)?.buttons.map(\.name), ["Help"])
    }

    func testDisabledButtonFlaggedNotDropped() {
        // A dialog whose default button is disabled is a real, observable state —
        // include it, flagged, never silently drop it.
        let forest = [node("AXSheet", title: "T", depth: 0, children: [
            button("Save", enabled: false, depth: 1),
            button("Cancel", enabled: true, depth: 1),
        ])]
        let d = DialogScan.detect(in: forest)!
        XCTAssertEqual(d.buttons, [
            DialogScan.Button(name: "Save", enabled: false),
            DialogScan.Button(name: "Cancel", enabled: true),
        ])
    }

    func testTitleExcludedFromMessageLines() {
        // A static text duplicating the title must NOT also appear as a message.
        let forest = [node("AXSheet", title: "Save?", depth: 0, children: [
            node("AXStaticText", value: "Save?", depth: 1),          // == title → excluded
            node("AXStaticText", value: "Unsaved changes.", depth: 1),
        ])]
        XCTAssertEqual(DialogScan.detect(in: forest)?.messageLines, ["Unsaved changes."])
    }

    func testDuplicateButtonsAndMessagesDeduped() {
        let forest = [node("AXSheet", title: "T", depth: 0, children: [
            node("AXStaticText", value: "Line", depth: 1),
            node("AXStaticText", value: "Line", depth: 1),          // dup
            button("OK", depth: 1),
            button("OK", depth: 1),                                  // dup
        ])]
        let d = DialogScan.detect(in: forest)!
        XCTAssertEqual(d.messageLines, ["Line"])
        XCTAssertEqual(d.buttons.map(\.name), ["OK"])
    }

    func testNestedDialogButtonsNotPulledIntoOuter() {
        // A (pathological) sheet containing a nested sheet — the nested modal's
        // buttons belong to it, not the outer one; only the outer's own buttons
        // are extracted.
        let forest = [node("AXSheet", title: "Outer", depth: 0, children: [
            button("Outer OK", depth: 1),
            node("AXSheet", title: "Inner", depth: 1, children: [
                button("Inner OK", depth: 2),
            ]),
        ])]
        let d = DialogScan.detect(in: forest)!
        XCTAssertEqual(d.title, "Outer")
        XCTAssertEqual(d.buttons.map(\.name), ["Outer OK"])
    }

    func testUntitledDialogHasNilTitle() {
        let forest = [node("AXSheet", depth: 0, children: [button("OK", depth: 1)])]
        XCTAssertNil(DialogScan.detect(in: forest)?.title)
    }

    func testDialogWithNoButtonsHasEmptyButtonList() {
        // A progress/spinner sheet with no buttons — honest empty list, never faked.
        let forest = [node("AXSheet", title: "Working…", depth: 0, children: [
            node("AXStaticText", value: "Please wait", depth: 1),
        ])]
        let d = DialogScan.detect(in: forest)!
        XCTAssertTrue(d.buttons.isEmpty)
        XCTAssertEqual(d.messageLines, ["Please wait"])
    }

    func testNonButtonControlsAreNotButtons() {
        // A popup/checkbox inside a sheet is not a dismissal "button" — only
        // AXButton roles are listed as choices.
        let forest = [node("AXSheet", title: "T", depth: 0, children: [
            node("AXPopUpButton", title: "Format", actions: ["AXPress"], depth: 1),
            node("AXCheckBox", title: "Remember", actions: ["AXPress"], depth: 1),
            button("Save", depth: 1),
        ])]
        XCTAssertEqual(DialogScan.detect(in: forest)?.buttons.map(\.name), ["Save"])
    }

    // MARK: - DismissVerdict (the pure dismiss decider)

    func testDialogGoneIsVerified() {
        guard case let .verified(evidence) =
            DismissVerdict.decide(button: "Cancel", readback: .gone) else {
            return XCTFail("a dialog observed gone after the press must VERIFY a dismissal")
        }
        XCTAssertTrue(evidence.contains("dismissed"))
        // The pressed button name is quoted into the evidence so the claim is auditable.
        XCTAssertTrue(evidence.contains("Cancel"))
    }

    func testDialogStillPresentIsDispatched() {
        // The press landed but a modal is still on screen (a validation block, or a
        // follow-up modal) → DISPATCHED-UNVERIFIED, never a faked dismissal.
        XCTAssertEqual(DismissVerdict.decide(button: "Save", readback: .stillPresent),
                       .dispatched)
    }

    func testUnreadableReadbackIsDispatchedNeverVerified() {
        // The honesty fix: when the post-press re-read could NOT be performed (the
        // AXWindows attribute errored — a transient read FAILURE, not a windowless
        // app), we must NOT treat the unreadable tree as "no modal → gone →
        // VERIFIED". A read we could not perform is an honest DISPATCHED-UNVERIFIED,
        // never a fabricated dismissal off an AX glitch.
        let result = DismissVerdict.decide(button: "Cancel", readback: .notObservable)
        XCTAssertEqual(result, .dispatched)
        // And it is specifically NOT a verified dismissal.
        if case .verified = result {
            XCTFail("an unobservable re-read must NEVER produce a verified dismissal")
        }
    }

    // MARK: - outcome honesty invariants

    func testDispatchedOutcomeIsNeverVerified() {
        let o = DialogClickOutcome(app: "TextEdit", button: "Save", role: "AXButton",
                                   axAccepted: true, verified: false, evidence: nil)
        XCTAssertTrue(o.axAccepted)
        XCTAssertFalse(o.verified)
        XCTAssertNil(o.evidence)
    }

    func testVerifiedOutcomeCarriesEvidence() {
        let o = DialogClickOutcome(app: "TextEdit", button: "Don't Save", role: "AXButton",
                                   axAccepted: true, verified: true,
                                   evidence: "dialog dismissed")
        XCTAssertTrue(o.verified)
        XCTAssertNotNil(o.evidence)
    }

    // MARK: - noDialog error honesty

    func testNoDialogErrorMessageIsHonest() {
        let msg = GhostHandsError.noDialog(app: "TextEdit").description
        XCTAssertTrue(msg.contains("TextEdit"))
        XCTAssertTrue(msg.lowercased().contains("no modal"))
        XCTAssertTrue(msg.lowercased().contains("refusing"))
    }
}
