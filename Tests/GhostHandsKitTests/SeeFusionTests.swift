import CoreGraphics
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE `see` fusion (dedup + rank + ref-assign), record round-trip,
/// and render, on FABRICATED inputs. NEVER drives a live app / opens a socket / runs
/// Vision (the env rule): every `SeeInput` is hand-built. The impure 3-eye gather
/// (`GhostHands.see`) is live-verified, not unit-tested.
final class SeeFusionTests: XCTestCase {

    private func ax(_ name: String, _ rect: CGRect?, interactive: Bool, role: String = "AXButton")
        -> SeeInput {
        SeeInput(source: .ax, role: role, name: name, rect: rect, interactive: interactive)
    }
    private func cdp(_ name: String, _ rect: CGRect?, interactive: Bool, ref: String?,
                     role: String = "button") -> SeeInput {
        SeeInput(source: .cdp, role: role, name: name, rect: rect, interactive: interactive,
                 cdpRef: ref)
    }
    private func ocr(_ text: String, _ rect: CGRect) -> SeeInput {
        SeeInput(source: .ocr, role: "text", name: text, rect: rect, interactive: false)
    }

    // MARK: iou

    func testIoU() {
        let r = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(SeeFusion.iou(r, r), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SeeFusion.iou(r, CGRect(x: 100, y: 100, width: 10, height: 10)), 0)
        // Half-overlap: intersection 5×10=50, union 200-50=150 → 1/3.
        let half = SeeFusion.iou(r, CGRect(x: 5, y: 0, width: 10, height: 10))
        XCTAssertEqual(half, 1.0 / 3.0, accuracy: 1e-9)
        // Degenerate rect → 0.
        XCTAssertEqual(SeeFusion.iou(r, CGRect(x: 0, y: 0, width: 0, height: 10)), 0)
    }

    // MARK: sameElement

    func testSameElementRectArm() {
        let a = ax("", CGRect(x: 0, y: 0, width: 20, height: 10), interactive: true)
        let b = ocr("Submit", CGRect(x: 1, y: 0, width: 20, height: 10)) // IoU high, same space
        XCTAssertTrue(SeeFusion.sameElement(a, b))
    }

    func testSameElementNameArmBridgesCoordSpaces() {
        // A CDP button (page coords) and its AX shadow (screen coords) — rects don't
        // overlap, but the equal name + both interactive + different sources collapse.
        let a = ax("Login", CGRect(x: 900, y: 700, width: 60, height: 20), interactive: true)
        let b = cdp("login", CGRect(x: 10, y: 40, width: 60, height: 20), interactive: true, ref: "@e3")
        XCTAssertTrue(SeeFusion.sameElement(a, b))   // case-insensitive name match
    }

    func testSameElementDoesNotMergeSameSourceTwins() {
        // Two distinct same-source "OK" buttons must NOT merge (name arm requires
        // different sources), and their rects don't overlap.
        let a = ax("OK", CGRect(x: 0, y: 0, width: 30, height: 20), interactive: true)
        let b = ax("OK", CGRect(x: 0, y: 100, width: 30, height: 20), interactive: true)
        XCTAssertFalse(SeeFusion.sameElement(a, b))
    }

    func testSameElementDoesNotMergeDifferentNames() {
        let a = ax("Save", CGRect(x: 0, y: 0, width: 30, height: 20), interactive: true)
        let b = cdp("Cancel", CGRect(x: 0, y: 0, width: 30, height: 20), interactive: true,
                    ref: "@e1")
        // Different names AND (page vs screen) rects that happen to overlap numerically
        // still merge via the rect arm — so use non-overlapping rects to isolate names.
        let b2 = cdp("Cancel", CGRect(x: 500, y: 500, width: 30, height: 20),
                     interactive: true, ref: "@e1")
        XCTAssertFalse(SeeFusion.sameElement(a, b2))
        _ = b
    }

    // MARK: fuse — dedup keeps the higher-priority source, preserves the cdp ref

    func testFuseCollapsesAxAndCdpToCdpKeepingRef() {
        let rows = SeeFusion.fuse([
            ax("Login", CGRect(x: 900, y: 700, width: 60, height: 20), interactive: true),
            cdp("Login", CGRect(x: 10, y: 40, width: 60, height: 20), interactive: true, ref: "@e3"),
        ])
        XCTAssertEqual(rows.count, 1)              // collapsed
        XCTAssertEqual(rows[0].source, .cdp)       // cdp wins (priority)
        XCTAssertEqual(rows[0].cdpRef, "@e3")      // ref preserved
    }

    func testFuseCollapsesAxAndOcrToAx() {
        let rows = SeeFusion.fuse([
            ax("Submit", CGRect(x: 0, y: 0, width: 20, height: 10), interactive: true),
            ocr("Submit", CGRect(x: 1, y: 0, width: 20, height: 10)),  // overlapping screen rect
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .ax)        // ax > ocr
    }

    func testFusePreservesCdpRefWhenAxIsTheWinner() {
        // If an AX row (higher priority than OCR but lower than CDP) collapses with a
        // CDP ref-carrying twin, the ref must survive even when CDP is the loser? No —
        // CDP is higher priority so CDP wins. This checks the merge ref-rescue: an AX
        // winner over an OCR loser keeps no ref (OCR has none) — sanity that ref stays nil.
        let rows = SeeFusion.fuse([
            ax("X", CGRect(x: 0, y: 0, width: 10, height: 10), interactive: true),
            ocr("X", CGRect(x: 0, y: 0, width: 10, height: 10)),
        ])
        XCTAssertNil(rows[0].cdpRef)
    }

    // MARK: fuse — ranking

    func testFuseRanksInteractiveThenNamedThenReadingOrder() {
        let interactiveLow = ax("Zeta", CGRect(x: 0, y: 500, width: 10, height: 10), interactive: true)
        let interactiveHigh = ax("Alpha", CGRect(x: 0, y: 100, width: 10, height: 10), interactive: true)
        let namedText = ax("Heading", CGRect(x: 0, y: 50, width: 10, height: 10),
                           interactive: false, role: "AXStaticText")
        let unnamed = ax("", CGRect(x: 0, y: 10, width: 10, height: 10),
                         interactive: false, role: "AXGroup")
        let rows = SeeFusion.fuse([unnamed, namedText, interactiveLow, interactiveHigh])
        // interactive first (top-to-bottom among them), then named text, then unnamed.
        XCTAssertEqual(rows.map(\.name), ["Alpha", "Zeta", "Heading", ""])
        XCTAssertEqual(rows.map(\.ref), ["@1", "@2", "@3", "@4"])
    }

    func testIsVisible() {
        XCTAssertTrue(SeeFusion.isVisible(CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertFalse(SeeFusion.isVisible(CGRect(x: 0, y: 100, width: 0, height: 0)))  // 0-area
        XCTAssertFalse(SeeFusion.isVisible(CGRect(x: 0, y: 0, width: 10, height: 0)))   // 0-height
        XCTAssertFalse(SeeFusion.isVisible(nil))
    }

    func testFuseRanksVisibleAboveZeroArea() {
        // A 0×0 INTERACTIVE node (e.g. a collapsed AX control) must rank BELOW a
        // visible NON-interactive one — a brain can't act on what isn't on screen.
        let zeroInteractive = ax("Hidden", CGRect(x: 0, y: 1440, width: 0, height: 0),
                                 interactive: true)
        let visibleText = ax("Shown", CGRect(x: 0, y: 10, width: 40, height: 20),
                             interactive: false, role: "AXStaticText")
        let rows = SeeFusion.fuse([zeroInteractive, visibleText])
        XCTAssertEqual(rows.map(\.name), ["Shown", "Hidden"])   // visible first
    }

    func testFuseAssignsSequentialRefs() {
        let rows = SeeFusion.fuse([
            ax("a", CGRect(x: 0, y: 0, width: 5, height: 5), interactive: true),
            ax("b", CGRect(x: 0, y: 20, width: 5, height: 5), interactive: true),
            ax("c", CGRect(x: 0, y: 40, width: 5, height: 5), interactive: true),
        ])
        XCTAssertEqual(rows.map(\.ref), ["@1", "@2", "@3"])
    }

    func testFuseEmptyInputIsEmpty() {
        XCTAssertEqual(SeeFusion.fuse([]).count, 0)
    }

    func testFuseNameBridgeGatedOnPerSourceUniqueness() {
        // A page with TWO distinct "Edit" links (CDP) + one AX "Edit" shadow, all in
        // non-overlapping rects. The name bridge must NOT fire (name not unique in the
        // CDP source), so NO distinct element is dropped — all three survive.
        let rows = SeeFusion.fuse([
            ax("Edit", CGRect(x: 900, y: 100, width: 40, height: 20), interactive: true),
            cdp("Edit", CGRect(x: 10, y: 40, width: 40, height: 20), interactive: true, ref: "@e1"),
            cdp("Edit", CGRect(x: 10, y: 90, width: 40, height: 20), interactive: true, ref: "@e2"),
        ])
        XCTAssertEqual(rows.count, 3)   // none collapsed — no real element lost
    }

    func testFuseNameBridgeFiresWhenNameUniquePerSource() {
        // A single "Login" in each source (unique) → the bridge fires → 1 row (cdp).
        let rows = SeeFusion.fuse([
            ax("Login", CGRect(x: 900, y: 700, width: 60, height: 20), interactive: true),
            cdp("Login", CGRect(x: 10, y: 40, width: 60, height: 20), interactive: true, ref: "@e3"),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .cdp)
    }

    // MARK: tier labels

    func testTierLabels() {
        XCTAssertEqual(SeeRow(ref: "@1", source: .ax, role: "AXButton", name: "x",
                              rect: nil, interactive: true).tier, "ax-press")
        XCTAssertEqual(SeeRow(ref: "@1", source: .ax, role: "AXStaticText", name: "x",
                              rect: nil, interactive: false).tier, "ax-read")
        XCTAssertEqual(SeeRow(ref: "@1", source: .cdp, role: "button", name: "x",
                              rect: nil, interactive: true).tier, "cdp")
        XCTAssertEqual(SeeRow(ref: "@1", source: .ocr, role: "text", name: "x",
                              rect: nil, interactive: false).tier, "hid-click")
    }

    // MARK: SeeRecord round-trip + Codable

    func testRecordRectRoundTrip() {
        let row = SeeRow(ref: "@2", source: .cdp, role: "input", name: "q",
                         rect: CGRect(x: 3, y: 4, width: 50, height: 12),
                         interactive: true, cdpRef: "@e9")
        let rec = SeeRecord(row: row)
        XCTAssertEqual(rec.rect, [3, 4, 50, 12])
        XCTAssertEqual(rec.cgRect, CGRect(x: 3, y: 4, width: 50, height: 12))
        XCTAssertEqual(rec.cdpRef, "@e9")
    }

    func testRecordRectlessIsNil() {
        let rec = SeeRecord(row: SeeRow(ref: "@1", source: .ocr, role: "text", name: "hi",
                                        rect: nil, interactive: false))
        XCTAssertNil(rec.rect)
        XCTAssertNil(rec.cgRect)
    }

    func testSnapshotCodableAndLookup() throws {
        let snap = SeeSnapshot(app: "Cursor", pid: 4242, port: 9333,
                               cdpTargetId: "TARGET-ABC", records: [
            SeeRecord(row: SeeRow(ref: "@1", source: .cdp, role: "div", name: "Agent",
                                  rect: nil, interactive: true, cdpRef: "@e1")),
        ])
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(SeeSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.pid, 4242)                // pid persists for A3 staleness
        XCTAssertEqual(back.cdpTargetId, "TARGET-ABC")  // F1: pin act's reattach renderer
        XCTAssertEqual(back.record(for: "@1")?.cdpRef, "@e1")
        XCTAssertNil(back.record(for: "@99"))         // missing ref → nil (caller re-sees)
    }

    // MARK: render

    func testRenderLine() {
        let row = SeeRow(ref: "@3", source: .ax, role: "AXButton", name: "Submit",
                         rect: CGRect(x: 10, y: 20, width: 60, height: 30), interactive: true)
        let line = SeeRender.line(row)
        XCTAssertTrue(line.hasPrefix("@3  AXButton \"Submit\""))
        XCTAssertTrue(line.contains("[ax] ax-press"))
    }

    func testRenderRectlessShowsFrameQuestion() {
        let row = SeeRow(ref: "@1", source: .ocr, role: "text", name: "hi",
                         rect: nil, interactive: false)
        XCTAssertTrue(SeeRender.line(row).contains("frame:?"))
    }
}
