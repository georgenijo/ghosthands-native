import CoreGraphics
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE scroll honesty core on FABRICATED facts. NEVER drives a
/// live app or reads a real scroll area: every input is a hand-built before/after
/// scroll-bar fraction, a direction/amount token, or a boxed AXValue. Covers the
/// required arms: position CHANGED ⇒ verified; UNCHANGED ⇒ dispatched (the
/// boundary-pinned / no-observable case is NEVER a fake success); plus the
/// direction/amount parser.
final class ScrollVerdictTests: XCTestCase {

    // MARK: ScrollVerdict.decide — the changed ⇒ verified / unchanged ⇒ dispatched core

    func testPositionMovedIsVerified() {
        // The bar moved from the top toward the middle ⇒ an observed world-change.
        XCTAssertEqual(ScrollVerdict.decide(before: 0.0, after: 0.18),
                       .verified(before: 0.0, after: 0.18))
    }

    func testPositionMovedUpwardIsVerified() {
        // A move toward 0.0 (scroll up) is just as much an observed change.
        XCTAssertEqual(ScrollVerdict.decide(before: 0.5, after: 0.3),
                       .verified(before: 0.5, after: 0.3))
    }

    func testUnchangedPositionIsDispatchedNotVerified() {
        // Identical before/after ⇒ the bar did not move ⇒ DISPATCHED (we looked,
        // it didn't move), NEVER a fabricated success.
        XCTAssertEqual(ScrollVerdict.decide(before: 0.42, after: 0.42),
                       .dispatched(observable: true))
    }

    func testBoundaryPinnedScrollIsDispatchedNotFakeSuccess() {
        // Already pinned at the bottom (1.0) and asked to scroll down again: the
        // bar cannot move. This is the load-bearing honesty rule — DISPATCHED,
        // never a fake verified.
        let v = ScrollVerdict.decide(before: 1.0, after: 1.0)
        XCTAssertEqual(v, .dispatched(observable: true))
        if case .verified = v { XCTFail("a boundary-pinned scroll must never be verified") }
    }

    func testSubEpsilonJitterStaysDispatched() {
        // A tiny sub-epsilon wobble (AX read jitter) must NOT register as a move.
        XCTAssertEqual(ScrollVerdict.decide(before: 0.5, after: 0.5 + 0.0001),
                       .dispatched(observable: true))
    }

    func testAtEpsilonIsVerified() {
        // The boundary is inclusive (>= epsilon). Use an exactly-comparable pair
        // (before 0, after = epsilon) so the assertion tests the >= rule itself,
        // not floating-point round-off of an offset from 0.5.
        let eps = ScrollVerdict.defaultEpsilon
        XCTAssertEqual(ScrollVerdict.decide(before: 0.0, after: eps),
                       .verified(before: 0.0, after: eps))
    }

    func testJustAboveEpsilonIsVerified() {
        // A move comfortably above epsilon (a real one-line scroll) is verified.
        XCTAssertEqual(ScrollVerdict.decide(before: 0.5, after: 0.51),
                       .verified(before: 0.5, after: 0.51))
    }

    func testNoReadableValueIsDispatchedNotObservable() {
        // No scroll-bar value to compare (nil) ⇒ we acted but could not look:
        // DISPATCHED with observable == false. Even a present 'after' cannot
        // upgrade it without a 'before' to compare against.
        XCTAssertEqual(ScrollVerdict.decide(before: nil, after: 0.3),
                       .dispatched(observable: false))
        XCTAssertEqual(ScrollVerdict.decide(before: 0.3, after: nil),
                       .dispatched(observable: false))
        XCTAssertEqual(ScrollVerdict.decide(before: nil, after: nil),
                       .dispatched(observable: false))
    }

    // MARK: ScrollSpec.parse — direction + amount

    func testDirectionParsesAllFour() {
        for (raw, expected) in [("up", ScrollSpec.Direction.up),
                                ("down", .down), ("left", .left), ("right", .right)] {
            let p = try? ScrollSpec.parse(direction: raw, amount: nil)
            XCTAssertEqual(p?.direction, expected)
        }
    }

    func testDirectionIsCaseInsensitive() {
        XCTAssertEqual(try? ScrollSpec.parse(direction: "DOWN", amount: nil).direction, .down)
        XCTAssertEqual(try? ScrollSpec.parse(direction: "Up", amount: nil).direction, .up)
    }

    func testUnknownDirectionRefuses() {
        XCTAssertThrowsError(try ScrollSpec.parse(direction: "sideways", amount: nil)) { err in
            XCTAssertEqual(err as? ScrollSpec.ParseError, .badDirection("sideways"))
        }
    }

    func testAbsentAmountDefaultsToOnePage() {
        let p = try? ScrollSpec.parse(direction: "down", amount: nil)
        XCTAssertEqual(p?.amount, ScrollSpec.defaultAmount)
        XCTAssertEqual(ScrollSpec.defaultAmount, 1.0)
    }

    func testPositiveAmountParses() {
        XCTAssertEqual(try? ScrollSpec.parse(direction: "down", amount: "3").amount, 3.0)
        XCTAssertEqual(try? ScrollSpec.parse(direction: "down", amount: "0.5").amount, 0.5)
    }

    func testZeroOrNegativeAmountRefuses() {
        // The amount is a magnitude (the direction carries the sign); 0 / negative
        // are nonsensical → REFUSE rather than guess.
        XCTAssertThrowsError(try ScrollSpec.parse(direction: "down", amount: "0")) { err in
            XCTAssertEqual(err as? ScrollSpec.ParseError, .badAmount("0"))
        }
        XCTAssertThrowsError(try ScrollSpec.parse(direction: "down", amount: "-2")) { err in
            XCTAssertEqual(err as? ScrollSpec.ParseError, .badAmount("-2"))
        }
    }

    func testNonNumericAmountRefuses() {
        XCTAssertThrowsError(try ScrollSpec.parse(direction: "down", amount: "lots")) { err in
            XCTAssertEqual(err as? ScrollSpec.ParseError, .badAmount("lots"))
        }
    }

    // MARK: ScrollSpec.Direction — axis + sign mapping

    func testVerticalAxisMapping() {
        XCTAssertTrue(ScrollSpec.Direction.up.isVertical)
        XCTAssertTrue(ScrollSpec.Direction.down.isVertical)
        XCTAssertFalse(ScrollSpec.Direction.left.isVertical)
        XCTAssertFalse(ScrollSpec.Direction.right.isVertical)
    }

    func testSignMapping() {
        // down/right increase the scroll-bar fraction (toward 1.0); up/left decrease it.
        XCTAssertEqual(ScrollSpec.Direction.down.sign, 1)
        XCTAssertEqual(ScrollSpec.Direction.right.sign, 1)
        XCTAssertEqual(ScrollSpec.Direction.up.sign, -1)
        XCTAssertEqual(ScrollSpec.Direction.left.sign, -1)
    }

    func testKnownDirectionsString() {
        XCTAssertEqual(ScrollSpec.Direction.known, "up | down | left | right")
    }

    // MARK: scrollFraction — boxed AXValue coercion (the witness read)

    func testScrollFractionReadsNSNumber() {
        XCTAssertEqual(GhostHands.scrollFraction(from: NSNumber(value: 0.37)), 0.37)
    }

    func testScrollFractionReadsDouble() {
        XCTAssertEqual(GhostHands.scrollFraction(from: 0.5 as Double), 0.5)
    }

    func testScrollFractionReadsNumericString() {
        XCTAssertEqual(GhostHands.scrollFraction(from: "0.25"), 0.25)
    }

    func testScrollFractionPeelsBoxedOptional() {
        // The AX generic Any fetch hands back a boxed Optional<NSNumber>.some(…) —
        // peel it (the same trap axString handles) rather than read a wrong value.
        let boxed: Any? = Optional(NSNumber(value: 0.8))
        XCTAssertEqual(GhostHands.scrollFraction(from: boxed as Any), 0.8)
    }

    func testScrollFractionNilForNonNumeric() {
        // A non-numeric / absent value yields nil (no observable) — never a guess.
        XCTAssertNil(GhostHands.scrollFraction(from: nil))
        XCTAssertNil(GhostHands.scrollFraction(from: "not-a-number"))
    }

    // MARK: ScrollAreaMatch.resolve — `--in` ambiguity refuse (pure, no live AX)

    private func area(title: String? = nil, id: String? = nil,
                     roleDesc: String? = nil, frame: CGRect? = nil) -> ScrollAreaMatch.Facts {
        ScrollAreaMatch.Facts(title: title, identifier: id, roleDescription: roleDesc, frame: frame)
    }

    func testResolveEmptyIsNone() {
        XCTAssertEqual(ScrollAreaMatch.resolve([]), .none)
    }

    func testResolveSingleCandidateIsUnique() {
        XCTAssertEqual(ScrollAreaMatch.resolve([area(title: "Sidebar")]), .unique(0))
    }

    func testResolveTwoDistinctAreasIsAmbiguous() {
        // Two scroll areas whose labels both contain the `--in` substring are a
        // wrong-target risk — REFUSE (ambiguous), never silently pick `.first`.
        let r = ScrollAreaMatch.resolve([area(title: "Sidebar List"),
                                         area(title: "Sidebar Detail")])
        XCTAssertEqual(r, .ambiguous(["Sidebar List", "Sidebar Detail"]))
    }

    func testResolveDuplicateRenderTwinsCollapseToUnique() {
        // The SAME logical scroll area rendered in two subtrees (identical title +
        // id + role-desc + frame) is ONE distinct container, not an ambiguity.
        let f = CGRect(x: 0, y: 0, width: 300, height: 800)
        let twins = [area(title: "List", id: "list", roleDesc: "scroll area", frame: f),
                     area(title: "List", id: "list", roleDesc: "scroll area", frame: f)]
        XCTAssertEqual(ScrollAreaMatch.resolve(twins), .unique(0))
    }

    func testResolveAmbiguityLabelFallsBackThroughFields() {
        // Distinct areas with no title still get a non-"?" label from identifier
        // / role-description so the refuse message names them.
        let r = ScrollAreaMatch.resolve([area(id: "left"), area(roleDesc: "right pane")])
        XCTAssertEqual(r, .ambiguous(["left", "right pane"]))
    }

    // MARK: ScrollAreaMatch.sameContainer — the before/after same-area guard

    func testSameContainerTrueForIdenticalStructure() {
        let f = CGRect(x: 10, y: 20, width: 300, height: 700)
        XCTAssertTrue(ScrollAreaMatch.sameContainer(
            area(title: "List", id: "list", frame: f),
            area(title: "List", id: "list", frame: f)))
    }

    func testSameContainerFalseWhenAreaDiffers() {
        // A divergent re-resolution (different area at a different frame) must NOT
        // be treated as the same container — the live verb drops `after` to nil so
        // a cross-container delta is never quoted as verified.
        XCTAssertFalse(ScrollAreaMatch.sameContainer(
            area(title: "Sidebar", frame: CGRect(x: 0, y: 0, width: 200, height: 600)),
            area(title: "Content", frame: CGRect(x: 200, y: 0, width: 800, height: 600))))
    }

    func testSameContainerFrameRoundsToWholePoints() {
        // Sub-point frame jitter between two reads of the SAME area must not break
        // identity (the key rounds to whole points).
        XCTAssertTrue(ScrollAreaMatch.sameContainer(
            area(title: "List", frame: CGRect(x: 0.2, y: 0.4, width: 300.1, height: 700.3)),
            area(title: "List", frame: CGRect(x: 0.0, y: 0.0, width: 300.0, height: 700.0))))
    }

    // MARK: ScrollOutcome honesty invariant (dispatched != verified)

    func testDispatchedOutcomeNotVerified() {
        let o = ScrollOutcome(app: "Safari", container: "scroll area", direction: .down,
                              amount: 1.0, via: "CGEvent wheel", dispatched: true,
                              verified: false, observable: true,
                              positionBefore: 1.0, positionAfter: 1.0)
        XCTAssertTrue(o.dispatched)
        XCTAssertFalse(o.verified)
    }
}
