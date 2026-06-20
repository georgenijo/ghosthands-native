import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE A3 actuator logic: the staleness decision (`ActRefPlan`) and
/// the hand selection (`ActHandPicker`), on FABRICATED snapshots/records. NEVER
/// drives a live app (the env rule); the impure `actRef` dispatch is live-verified.
final class ActRefTests: XCTestCase {

    private func rec(_ ref: String, source: SeeSource, cdpRef: String? = nil) -> SeeRecord {
        SeeRecord(ref: ref, source: source, role: "button", name: "Go",
                  rect: nil, interactive: true, cdpRef: cdpRef)
    }
    private func snap(app: String, pid: Int32?, records: [SeeRecord]) -> SeeSnapshot {
        SeeSnapshot(app: app, pid: pid, port: 9333, records: records)
    }

    // MARK: ActRefPlan.decide — staleness gate

    func testDecideNoSnapshot() {
        XCTAssertEqual(
            ActRefPlan.decide(snapshot: nil, ref: "@1", appName: "Cursor", livePID: 1),
            .noSnapshot)
    }

    func testDecideAppMismatch() {
        let s = snap(app: "Brave Browser", pid: 10, records: [rec("@1", source: .cdp, cdpRef: "@e1")])
        XCTAssertEqual(
            ActRefPlan.decide(snapshot: s, ref: "@1", appName: "Cursor", livePID: 10),
            .appMismatch(snapshotApp: "Brave Browser", requested: "Cursor"))
    }

    func testDecideRelaunchedOnPidChange() {
        let s = snap(app: "Cursor", pid: 100, records: [rec("@1", source: .ax)])
        XCTAssertEqual(
            ActRefPlan.decide(snapshot: s, ref: "@1", appName: "Cursor", livePID: 999),
            .relaunched)
    }

    func testDecideUnknownRef() {
        let s = snap(app: "Cursor", pid: 100, records: [rec("@1", source: .ax)])
        XCTAssertEqual(
            ActRefPlan.decide(snapshot: s, ref: "@7", appName: "Cursor", livePID: 100),
            .unknownRef)
    }

    func testDecideProceed() {
        let r = rec("@2", source: .cdp, cdpRef: "@e9")
        let s = snap(app: "Cursor", pid: 100, records: [r])
        XCTAssertEqual(
            ActRefPlan.decide(snapshot: s, ref: "@2", appName: "Cursor", livePID: 100),
            .proceed(r))
    }

    func testDecideNilPidSkipsRelaunchGuard() {
        // An older snapshot with no pid still resolves by app-name + ref (no relaunch
        // guard, since there is nothing to compare).
        let r = rec("@1", source: .ax)
        let s = snap(app: "Cursor", pid: nil, records: [r])
        XCTAssertEqual(
            ActRefPlan.decide(snapshot: s, ref: "@1", appName: "Cursor", livePID: 5),
            .proceed(r))
    }

    // MARK: ActHandPicker.pick — auto-pick the hand by source

    func testPickAx() {
        XCTAssertEqual(ActHandPicker.pick(rec("@1", source: .ax), typing: false), .hand(.axPress))
        XCTAssertEqual(ActHandPicker.pick(rec("@1", source: .ax), typing: true), .hand(.axType))
    }

    func testPickCdpWithRef() {
        let r = rec("@1", source: .cdp, cdpRef: "@e1")
        XCTAssertEqual(ActHandPicker.pick(r, typing: false), .hand(.cdpClick))
        XCTAssertEqual(ActHandPicker.pick(r, typing: true), .hand(.cdpType))
    }

    func testPickCdpWithoutRefRefuses() {
        // A cdp row that somehow lost its @eN handle can't be CDP-actuated → refuse.
        let r = rec("@1", source: .cdp, cdpRef: nil)
        guard case .refuse = ActHandPicker.pick(r, typing: false) else {
            return XCTFail("cdp row without a ref should refuse")
        }
    }

    func testPickOcr() {
        XCTAssertEqual(ActHandPicker.pick(rec("@1", source: .ocr), typing: false), .hand(.hidClick))
        // ocr + type → refuse (no field handle to type into).
        XCTAssertEqual(ActHandPicker.pick(rec("@1", source: .ocr), typing: true),
                       .refuse(reason: "ocr-only"))
    }

    // MARK: - AX identity pin: two same-named controls resolve to the RIGHT one

    /// A fabricated control list with TWO distinct, same-named, same-ROLE buttons
    /// (the wrong-target case the ref pin must defeat): "Edit" #0 and "Edit" #1,
    /// told apart by value. `act`-time resolution is `Locator.refine` over THIS list
    /// using the spec the stored `SeeRecord` carries — so this exercises the exact
    /// path `actRef` takes (minus the live AX walk, per the no-live-app rule).
    private func twoSameNamed() -> [ElementFacts] {
        [ElementFacts(role: "AXButton", title: "Edit", value: "first", supportsPress: true),
         ElementFacts(role: "AXButton", title: "Edit", value: "second", supportsPress: true)]
    }

    private func axRecord(ref: String, name: String, role: String, axIndex: Int?) -> SeeRecord {
        SeeRecord(ref: ref, source: .ax, role: role, name: name,
                  rect: nil, interactive: true, cdpRef: nil, axIndex: axIndex)
    }

    func testStoredIdentityResolvesFirstOfTwoSameNamed() {
        // The see snapshot pinned ref "@1" to the FIRST "Edit" (nth 0). Re-resolving
        // its stored identity on the (fresh) candidate list must land on index 0, NOT
        // refuse as ambiguous and NOT pick the wrong twin.
        let r = axRecord(ref: "@1", name: "Edit", role: "AXButton", axIndex: 0)
        let spec = r.axLocator
        XCTAssertEqual(spec.role, "AXButton")
        XCTAssertEqual(spec.nth, 0)
        guard case .one(0) = Locator.refine(twoSameNamed(), query: "Edit",
                                            role: spec.role, text: spec.text, nth: spec.nth) else {
            return XCTFail("stored identity of @1 must re-resolve to the FIRST Edit (index 0)")
        }
    }

    func testStoredIdentityResolvesSecondOfTwoSameNamed() {
        // ref "@2" was pinned to the SECOND "Edit" (nth 1) — the case where re-finding
        // by NAME alone would have refused (ambiguous) or hit the wrong control.
        let r = axRecord(ref: "@2", name: "Edit", role: "AXButton", axIndex: 1)
        let spec = r.axLocator
        XCTAssertEqual(spec.nth, 1)
        guard case .one(1) = Locator.refine(twoSameNamed(), query: "Edit",
                                            role: spec.role, text: spec.text, nth: spec.nth) else {
            return XCTFail("stored identity of @2 must re-resolve to the SECOND Edit (index 1)")
        }
    }

    func testNameAloneWouldRefuseProvingThePinIsNeeded() {
        // CONTROL: the OLD behavior (re-find by name alone, no locator) is AMBIGUOUS
        // over the same two controls — proving the stored nth is what disambiguates.
        guard case .ambiguous = Locator.refine(twoSameNamed(), query: "Edit",
                                               role: nil, text: nil, nth: nil) else {
            return XCTFail("name alone over two same-named controls must be ambiguous")
        }
    }

    func testStoredIndexOutOfRangeRefusesAfterChurn() {
        // HONESTY: if UI churn left only ONE same-named survivor, a stored nth of 1
        // must REFUSE (index out of range) — never silently act on the lone survivor,
        // which could be the WRONG control.
        let oneLeft = [ElementFacts(role: "AXButton", title: "Edit", supportsPress: true)]
        let r = axRecord(ref: "@2", name: "Edit", role: "AXButton", axIndex: 1)
        guard case .indexOutOfRange(requested: 1, count: 1) =
            Locator.refine(oneLeft, query: "Edit",
                           role: r.axLocator.role, text: r.axLocator.text, nth: r.axLocator.nth) else {
            return XCTFail("a stale nth past the surviving count must refuse, not guess")
        }
    }

    func testUnpinnedAxRecordFallsBackToRolePin() {
        // When see could NOT stamp an index (axIndex nil), the locator still pins the
        // ROLE — narrowing a same-named control of a DIFFERENT role to the right one,
        // and otherwise refusing on a remaining ambiguity (never guessing).
        let r = axRecord(ref: "@1", name: "Save", role: "AXMenuButton", axIndex: nil)
        XCTAssertNil(r.axLocator.nth)
        let cands = [ElementFacts(role: "AXButton", title: "Save", supportsPress: true),
                     ElementFacts(role: "AXMenuButton", title: "Save", supportsPress: true)]
        guard case .one(1) = Locator.refine(cands, query: "Save",
                                            role: r.axLocator.role, text: r.axLocator.text,
                                            nth: r.axLocator.nth) else {
            return XCTFail("an unpinned record must still narrow by role to the AXMenuButton")
        }
    }
}
