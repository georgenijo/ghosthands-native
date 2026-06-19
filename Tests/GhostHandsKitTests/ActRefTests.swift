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
}
