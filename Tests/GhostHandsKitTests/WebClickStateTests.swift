import XCTest
@testable import GhostHandsKit

/// Hermetic — issue #6: the PURE in-page (non-navigating) `web click` verification.
/// `stateFlip` + the 4-arg `clickVerdict` over FABRICATED before/after state dicts;
/// no socket, no browser. Navigation still wins; a proven toggle earns verified; an
/// unstable/absent read stays honestly dispatched-unverified.
final class WebClickStateTests: XCTestCase {

    private func isVerified(_ v: WebActuate.Verdict) -> Bool {
        if case .verified = v { return true }; return false
    }
    private func evidence(_ v: WebActuate.Verdict) -> String {
        switch v { case let .verified(e): return e; case let .dispatchedUnverified(r): return r }
    }

    // MARK: stateFlip

    func testFlipDetectsAriaPressedChange() {
        let f = WebActuate.stateFlip(before: ["aria-pressed": "false"],
                                     after: ["aria-pressed": "true"])
        XCTAssertEqual(f?.signal, "aria-pressed")
        XCTAssertEqual(f?.before, "false")
        XCTAssertEqual(f?.after, "true")
    }

    func testNoFlipWhenUnchanged() {
        XCTAssertNil(WebActuate.stateFlip(before: ["aria-checked": "true"],
                                          after: ["aria-checked": "true"]))
    }

    func testKeyOnlyOnOneSideIsNotAFlip() {
        // A key that appeared/vanished between reads is an UNSTABLE read, not a proven
        // flip — must be ignored (no over-claim).
        XCTAssertNil(WebActuate.stateFlip(before: [:], after: ["aria-pressed": "true"]))
        XCTAssertNil(WebActuate.stateFlip(before: ["aria-pressed": "true"], after: [:]))
    }

    func testNilSideIsNoFlip() {
        XCTAssertNil(WebActuate.stateFlip(before: nil, after: ["aria-pressed": "true"]))
        XCTAssertNil(WebActuate.stateFlip(before: ["aria-pressed": "true"], after: nil))
    }

    func testCheckedBooleanFlip() {
        // JS booleans decode to NSNumber/Bool — stateString normalizes both sides.
        let f = WebActuate.stateFlip(before: ["checked": false], after: ["checked": true])
        XCTAssertEqual(f?.signal, "checked")
        XCTAssertEqual(f?.before, "false")
        XCTAssertEqual(f?.after, "true")
    }

    func testPriorityAriaBeatsClassName() {
        // Both aria-pressed AND className changed → the higher-priority signal wins.
        let f = WebActuate.stateFlip(
            before: ["aria-pressed": "false", "className": "btn"],
            after: ["aria-pressed": "true", "className": "btn active"])
        XCTAssertEqual(f?.signal, "aria-pressed")
    }

    func testClassNameFlipWhenItIsTheOnlySignal() {
        let f = WebActuate.stateFlip(before: ["className": "tab"],
                                     after: ["className": "tab selected"])
        XCTAssertEqual(f?.signal, "className")
    }

    // MARK: 4-arg clickVerdict

    func testNavigationStillWinsOverState() {
        // A changed href is verified by navigation; state is not even consulted.
        let v = WebActuate.clickVerdict(hrefBefore: "https://a/", hrefAfter: "https://b/",
                                        stateBefore: ["aria-pressed": "true"],
                                        stateAfter: ["aria-pressed": "true"])
        XCTAssertTrue(isVerified(v))
        XCTAssertTrue(evidence(v).contains("navigated"))
    }

    func testInPageFlipEarnsVerifiedWhenNoNavigation() {
        let v = WebActuate.clickVerdict(hrefBefore: "https://a/", hrefAfter: "https://a/",
                                        stateBefore: ["aria-expanded": "false"],
                                        stateAfter: ["aria-expanded": "true"])
        XCTAssertTrue(isVerified(v))
        XCTAssertTrue(evidence(v).contains("aria-expanded"))
        XCTAssertTrue(evidence(v).contains("no navigation"))
    }

    func testNoNavNoFlipStaysDispatched() {
        let v = WebActuate.clickVerdict(hrefBefore: "https://a/", hrefAfter: "https://a/",
                                        stateBefore: ["aria-pressed": "true"],
                                        stateAfter: ["aria-pressed": "true"])
        XCTAssertFalse(isVerified(v))
        XCTAssertTrue(evidence(v).contains("unverified"))
    }

    func testNoNavNilStateStaysDispatched() {
        let v = WebActuate.clickVerdict(hrefBefore: "https://a/", hrefAfter: "https://a/",
                                        stateBefore: nil, stateAfter: nil)
        XCTAssertFalse(isVerified(v))
    }
}
