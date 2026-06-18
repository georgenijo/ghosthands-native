import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE right-click verdict decider on FABRICATED facts. NEVER
/// drives a live app or opens a real menu: every input is a hand-built
/// before/after `AXMenu` count + a dispatched flag.
///
/// A right-click's ONLY honest self-observable is that a context `AXMenu`
/// appears, so the decider promotes to VERIFIED exactly when the menu count
/// GREW across the action, and otherwise reports an honest DISPATCHED-UNVERIFIED
/// — the same verdict whether the menu was opened via AXShowMenu or a pixel
/// right-click (honesty does not depend on the route). The required arms:
///   - menu appeared (after > before)            -> VERIFIED
///   - accepted but no menu (after == before)    -> DISPATCHED  (AX route)
///   - pixel route, no menu observed             -> DISPATCHED
///   - pixel route, menu appeared                -> VERIFIED (route-agnostic)
///   - not dispatched                            -> REFUSE (defensive guard)
/// plus the candidate-gate / outcome-honesty / error-message invariants.
final class RightClickVerdictTests: XCTestCase {

    // MARK: MenuVerdict — the menu-appeared promotion (VERIFIED arm)

    func testNewMenuAppearedIsVerified() {
        // A context menu popped in: 0 -> 1 AXMenu -> VERIFIED, with auditable evidence.
        guard case let .verified(evidence) =
            MenuVerdict.decide(dispatched: true, menusBefore: 0, menusAfter: 1) else {
            return XCTFail("a newly-present context menu must verify a right-click")
        }
        XCTAssertTrue(evidence.contains("context menu appeared"))
        XCTAssertTrue(evidence.contains("0 → 1"))
    }

    func testMenuAppearedAmidExistingMenusStillVerifiesOnIncrease() {
        // The witness fires on an INCREASE, not an absolute count: 1 -> 2 is proof
        // a NEW menu opened even though a menu already existed.
        guard case let .verified(evidence) =
            MenuVerdict.decide(dispatched: true, menusBefore: 1, menusAfter: 2) else {
            return XCTFail("an increased menu count must verify")
        }
        XCTAssertTrue(evidence.contains("1 → 2"))
    }

    // MARK: MenuVerdict — accepted-but-no-menu (the AX-route DISPATCHED arm)

    func testAxAcceptedButNoMenuIsDispatched() {
        // AXShowMenu was performed (dispatched) but the menu count did not grow —
        // honest DISPATCHED-UNVERIFIED, never a fabricated success.
        XCTAssertEqual(MenuVerdict.decide(dispatched: true, menusBefore: 0, menusAfter: 0),
                       .dispatched)
    }

    func testMenuCountUnchangedAtNonZeroIsDispatched() {
        // A menu was already open and nothing new appeared (e.g. a no-op perform)
        // -> still DISPATCHED; a steady count is not proof.
        XCTAssertEqual(MenuVerdict.decide(dispatched: true, menusBefore: 1, menusAfter: 1),
                       .dispatched)
    }

    func testMenuCountDroppedIsDispatched() {
        // A menu DISAPPEARING (a stale menu closed) is not a right-click effect we
        // can claim -> honest DISPATCHED (never read a decrease as a success).
        XCTAssertEqual(MenuVerdict.decide(dispatched: true, menusBefore: 2, menusAfter: 1),
                       .dispatched)
    }

    // MARK: MenuVerdict — the pixel route (route-agnostic verdict)

    func testPixelRouteWithMenuAppearedIsVerified() {
        // A pixel right-click has no self-signal, BUT if a context AXMenu still
        // appears we promote to VERIFIED — the verdict is identical to the AX
        // route (it depends only on whether a menu was OBSERVED, not on how).
        guard case .verified = MenuVerdict.decide(dispatched: true, menusBefore: 0, menusAfter: 1) else {
            return XCTFail("a pixel right-click that opens a menu must still verify")
        }
    }

    func testPixelRouteWithNoMenuIsDispatched() {
        // The canonical pixel case: posted the right-click, no observable menu
        // (postToPid ignored, or the surface shows no AX menu) -> DISPATCHED.
        XCTAssertEqual(MenuVerdict.decide(dispatched: true, menusBefore: 0, menusAfter: 0),
                       .dispatched)
    }

    // MARK: MenuVerdict — the REFUSE arm (defensive: action never sent)

    func testNotDispatchedIsRefuse() {
        // If the action was never even sent, the decider refuses (the live verb
        // raises upstream; this keeps the enum total and never fakes a verdict).
        XCTAssertEqual(MenuVerdict.decide(dispatched: false, menusBefore: 0, menusAfter: 5),
                       .refuse)
        // A non-dispatched call can never be VERIFIED even with a high after-count.
        XCTAssertNotEqual(MenuVerdict.decide(dispatched: false, menusBefore: 0, menusAfter: 9),
                          .verified(evidence: "context menu appeared (0 → 9 menus)"))
    }

    // MARK: evidence pluralisation (cosmetic honesty — exact before→after quoted)

    func testEvidencePluralisesMenuNoun() {
        guard case let .verified(one) =
            MenuVerdict.decide(dispatched: true, menusBefore: 0, menusAfter: 1) else {
            return XCTFail("expected verified")
        }
        XCTAssertTrue(one.hasSuffix("menu)"), "a delta of 1 reads 'menu': \(one)")
        guard case let .verified(two) =
            MenuVerdict.decide(dispatched: true, menusBefore: 0, menusAfter: 2) else {
            return XCTFail("expected verified")
        }
        XCTAssertTrue(two.hasSuffix("menus)"), "a delta of 2 reads 'menus': \(two)")
    }

    // MARK: candidate gate — isRightClickable (PURE over fabricated facts)

    func testButtonIsRightClickable() {
        // A pushable control role qualifies (it can carry a context menu).
        let f = ElementFacts(role: "AXButton", supportsPress: true,
                             supportedActions: ["AXPress"])
        XCTAssertTrue(GhostHands.isRightClickable(f))
    }

    func testRowIsRightClickable() {
        // A Finder/list row is a prime right-click target (openable gate).
        let f = ElementFacts(role: "AXRow", supportedActions: [])
        XCTAssertTrue(GhostHands.isRightClickable(f))
    }

    func testContentRolesAreRightClickable() {
        // Static text / image / group / text fields commonly own a context menu.
        for role in ["AXStaticText", "AXImage", "AXGroup", "AXTextField", "AXTextArea"] {
            XCTAssertTrue(GhostHands.isRightClickable(ElementFacts(role: role)),
                          "\(role) should be right-clickable content")
        }
    }

    func testAnyControlAdvertisingShowMenuIsRightClickable() {
        // An odd role that advertises AXShowMenu is accepted regardless of role.
        let f = ElementFacts(role: "AXUnknown", supportedActions: ["AXShowMenu"])
        XCTAssertTrue(GhostHands.isRightClickable(f))
    }

    func testPlainUnknownRoleWithoutShowMenuIsNotRightClickable() {
        // A non-content, non-control role that advertises nothing is excluded —
        // we do not right-click an arbitrary structural node.
        let f = ElementFacts(role: "AXSplitter", supportedActions: [])
        XCTAssertFalse(GhostHands.isRightClickable(f))
    }

    // MARK: RightClickOutcome honesty invariants (dispatched != verified)

    func testDispatchedOutcomeNotVerified() {
        // AXShowMenu sent but no menu observed: dispatched true, verified false.
        let o = RightClickOutcome(app: "Finder", name: "report.pdf", role: "AXRow",
                                  route: .axShowMenu, dispatched: true, verified: false,
                                  evidence: nil)
        XCTAssertTrue(o.dispatched)
        XCTAssertFalse(o.verified)
        XCTAssertNil(o.evidence)
    }

    func testVerifiedOutcomeCarriesEvidenceAndRoute() {
        let o = RightClickOutcome(app: "Finder", name: "report.pdf", role: "AXRow",
                                  route: .axShowMenu, dispatched: true, verified: true,
                                  evidence: "context menu appeared (0 → 1 menu)")
        XCTAssertTrue(o.verified)
        XCTAssertEqual(o.route, .axShowMenu)
        XCTAssertEqual(o.evidence, "context menu appeared (0 → 1 menu)")
    }

    func testPixelOutcomeDefaultsToInvisibleMode() {
        // The default delivery mode is invisible (the labelled --visible HID path
        // is opt-in), mirroring the pixel-click contract.
        let o = RightClickOutcome(app: "TextEdit", name: "Body", role: "AXTextArea",
                                  route: .pixel, dispatched: true, verified: false,
                                  evidence: nil)
        XCTAssertEqual(o.mode, .invisible)
    }

    func testPixelOutcomeCarriesVisibleMode() {
        let o = RightClickOutcome(app: "TextEdit", name: "Body", role: "AXTextArea",
                                  route: .pixel, mode: .visible, dispatched: true,
                                  verified: true, evidence: "context menu appeared (0 → 1 menu)")
        XCTAssertEqual(o.mode, .visible)
        XCTAssertEqual(o.route, .pixel)
    }

    // MARK: error message (the one-line honest refuse)

    func testNoElementFrameErrorIsHonest() {
        let msg = "\(GhostHandsError.noElementFrame(name: "Body"))"
        XCTAssertTrue(msg.contains("Body"))
        XCTAssertTrue(msg.contains("AXShowMenu"))
        XCTAssertTrue(msg.contains("refusing"))
    }
}
