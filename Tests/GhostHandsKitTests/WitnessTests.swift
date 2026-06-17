import XCTest
@testable import GhostHandsKit

/// Hermetic — the effect-witness diff + click verdict, with FABRICATED
/// witnesses (no live app). This is the M2 honesty surface: it must VERIFY only
/// on an observed, attributable change and must UNDER-CLAIM (stay dispatched)
/// when nothing changed or when the change can't be isolated.
final class WitnessTests: XCTestCase {
    private func w(_ key: String, _ name: String, _ value: String?) -> WitnessMatch.Witness {
        WitnessMatch.Witness(key: key, name: name, value: value)
    }

    // MARK: WitnessMatch.diff

    func testSingleWitnessChangeIsAttributed() {
        let before = [w("display", "display", "0")]
        let after = [w("display", "display", "789")]
        guard case let .changed(name, b, a) = WitnessMatch.diff(before: before, after: after) else {
            return XCTFail("a single value flip must be .changed")
        }
        XCTAssertEqual(name, "display")
        XCTAssertEqual(b, "0")
        XCTAssertEqual(a, "789")
    }

    func testNoChangeIsNone() {
        let before = [w("display", "display", "0")]
        let after = [w("display", "display", "0")]
        XCTAssertEqual(WitnessMatch.diff(before: before, after: after), .none)
    }

    func testTwoChangesDemoteToAmbiguous() {
        // A live clock AND the display both moved — we cannot attribute the
        // effect to our press, so demote (the SAFE direction, never over-claim).
        let before = [w("display", "display", "0"), w("clock", "clock", "10:00")]
        let after = [w("display", "display", "7"), w("clock", "clock", "10:01")]
        guard case let .ambiguous(names) = WitnessMatch.diff(before: before, after: after) else {
            return XCTFail("two simultaneous changes must be .ambiguous")
        }
        XCTAssertEqual(Set(names), Set(["display", "clock"]))
    }

    func testDisappearedWitnessIsNotAValueFlip() {
        // A witness present before but gone after is NOT a quotable value change.
        let before = [w("display", "display", "0")]
        let after: [WitnessMatch.Witness] = []
        XCTAssertEqual(WitnessMatch.diff(before: before, after: after), .none)
    }

    func testAppearedWitnessIsNotAValueFlip() {
        let before: [WitnessMatch.Witness] = []
        let after = [w("display", "display", "789")]
        XCTAssertEqual(WitnessMatch.diff(before: before, after: after), .none)
    }

    func testKeyExcludesValueSoSameElementMatches() {
        // Identity is the key, NOT the value — same element, new value → changed,
        // never seen as gone+new.
        let before = [w("k", "field", "abc")]
        let after = [w("k", "field", "abcd")]
        guard case .changed = WitnessMatch.diff(before: before, after: after) else {
            return XCTFail("same key, different value must be a change")
        }
    }

    func testNilToValueOnAStableKeyIsAChange() {
        // The headline collection fix (found by live-verify): an EMPTY readout —
        // value nil, but a real element with a stable key — that GAINS a value is
        // a genuine, attributable change, NOT an "appeared". Witnesses are now
        // collected even while blank, so a blank calculator display flips
        // nil → "789" under one stable key and `diff` reports it. Without this,
        // the single most common effect (empty field gains text) silently
        // under-claimed as DISPATCHED-UNVERIFIED.
        let before = [w("display", "display", nil)]
        let after = [w("display", "display", "789")]
        guard case let .changed(name, b, a) = WitnessMatch.diff(before: before, after: after) else {
            return XCTFail("nil → value on a stable key must be .changed")
        }
        XCTAssertEqual(name, "display")
        XCTAssertNil(b)
        XCTAssertEqual(a, "789")
    }

    // MARK: colliding-key safety (Finding 2 — false VERIFIED on a no-op press)

    func testCollidingKeysNothingChangedIsNone() {
        // Two DISTINCT siblings collapse onto the same key K (e.g. two untitled
        // AXStaticText with nil frames). NOTHING actually changed. The pre-fix
        // diff fabricated a `.changed(B 5 → 0)` because afterByKey kept only the
        // last writer; a non-unique key must be dropped → `.none`.
        let before = [w("K", "A", "5"), w("K", "B", "0")]
        let after = [w("K", "A", "5"), w("K", "B", "0")]
        XCTAssertEqual(WitnessMatch.diff(before: before, after: after), .none,
                       "a no-op press over colliding keys must never be VERIFIED")
    }

    func testCollidingKeysWithRealChangeStillNotAttributed() {
        // Even if one of the colliding siblings genuinely changed, the key is
        // un-pairable, so we cannot attribute the change to a specific element →
        // under-claim (.none) rather than risk quoting the wrong before→after.
        let before = [w("K", "A", "5"), w("K", "B", "0")]
        let after = [w("K", "A", "5"), w("K", "B", "9")]
        XCTAssertEqual(WitnessMatch.diff(before: before, after: after), .none)
    }

    func testUniqueKeyStillChangesAlongsideACollidingPair() {
        // A genuine single change under a UNIQUE key must still be .changed even
        // when an unrelated colliding pair is present (the collision is dropped,
        // the unique witness survives).
        let before = [w("dup", "A", "1"), w("dup", "B", "2"), w("disp", "display", "0")]
        let after = [w("dup", "A", "1"), w("dup", "B", "2"), w("disp", "display", "7")]
        guard case let .changed(name, b, a) = WitnessMatch.diff(before: before, after: after) else {
            return XCTFail("a unique-key change must survive a colliding pair")
        }
        XCTAssertEqual(name, "display")
        XCTAssertEqual(b, "0")
        XCTAssertEqual(a, "7")
    }

    func testKeyCollidesOnlyAfterIsDropped() {
        // Unique before, but a transient duplicate appears after under that key:
        // still un-pairable on the after side → not attributable → .none.
        let before = [w("K", "field", "0")]
        let after = [w("K", "field", "7"), w("K", "ghost", "x")]
        XCTAssertEqual(WitnessMatch.diff(before: before, after: after), .none)
    }

    // MARK: WitnessMatch.stable (causation fence)

    func testStableKeepsSettledWitness() {
        // A press drives the display to a NEW value that then holds across both
        // post-press reads → it survives the stability fence and can be quoted.
        let after1 = [w("display", "display", "789")]
        let after2 = [w("display", "display", "789")]
        XCTAssertEqual(WitnessMatch.stable(after1, after2), after1)
    }

    func testStableDropsStillChangingWitness() {
        // A live clock keeps moving between the two reads → unstable → dropped,
        // so it can never be quoted as the press's effect.
        let after1 = [w("clock", "clock", "10:01")]
        let after2 = [w("clock", "clock", "10:02")]
        XCTAssertTrue(WitnessMatch.stable(after1, after2).isEmpty)
    }

    func testStableThenDiffIgnoresAClockButKeepsTheDisplay() {
        // The end-to-end causation guard: BEFORE has display 0 + clock 10:00;
        // the press settles the display to 7 while the clock keeps ticking.
        // After stabilising, only the display survives → exactly one change.
        let before = [w("display", "display", "0"), w("clock", "clock", "10:00")]
        let after1 = [w("display", "display", "7"), w("clock", "clock", "10:01")]
        let after2 = [w("display", "display", "7"), w("clock", "clock", "10:02")]
        let settled = WitnessMatch.stable(after1, after2)
        guard case let .changed(name, b, a) = WitnessMatch.diff(before: before, after: settled) else {
            return XCTFail("a settled display change beside a ticking clock must be .changed")
        }
        XCTAssertEqual(name, "display")
        XCTAssertEqual(b, "0")
        XCTAssertEqual(a, "7")
    }

    func testStableDropsKeyMissingFromSecondRead() {
        // Present in after1 but gone (or un-pairable) in after2 → not settled.
        let after1 = [w("k", "field", "x")]
        let after2: [WitnessMatch.Witness] = []
        XCTAssertTrue(WitnessMatch.stable(after1, after2).isEmpty)
    }

    func testStableDropsCollidingKeys() {
        // A key seen twice on either read can't be paired → dropped.
        let after1 = [w("K", "A", "1"), w("K", "B", "2")]
        let after2 = [w("K", "A", "1"), w("K", "B", "2")]
        XCTAssertTrue(WitnessMatch.stable(after1, after2).isEmpty)
    }

    // MARK: WitnessMatch.readout

    func testReadoutPrefersValue() {
        XCTAssertEqual(
            WitnessMatch.readout(value: "789", identifier: "StandardInputView;value:0",
                                 description: "Edit field"),
            "789")
    }

    func testReadoutFallsBackToIdentifierWhenValueEmpty() {
        // The Calculator case: AXValue nil, the live value rides on the id.
        XCTAssertEqual(
            WitnessMatch.readout(value: nil, identifier: "StandardInputView;value:789",
                                 description: "Edit field"),
            "StandardInputView;value:789")
        XCTAssertEqual(
            WitnessMatch.readout(value: "", identifier: "StandardInputView;value:789",
                                 description: nil),
            "StandardInputView;value:789")
    }

    func testReadoutFallsBackToDescriptionLast() {
        XCTAssertEqual(
            WitnessMatch.readout(value: nil, identifier: nil, description: "Edit field"),
            "Edit field")
    }

    func testReadoutNilWhenAllEmpty() {
        XCTAssertNil(WitnessMatch.readout(value: nil, identifier: nil, description: nil))
        XCTAssertNil(WitnessMatch.readout(value: "", identifier: "", description: ""))
    }

    func testIdentifierEncodedValueFlipIsAChange() {
        // End-to-end of the Calculator fix at the diff layer: the scroll area's
        // readout (its identifier) flips while its STRUCTURAL key is unchanged.
        let before = [w("AXScrollArea\u{1}\u{1}10,10,200,40\u{1}.0", "ScrollArea",
                        "StandardInputView;value:0")]
        let after = [w("AXScrollArea\u{1}\u{1}10,10,200,40\u{1}.0", "ScrollArea",
                       "StandardInputView;value:789")]
        guard case let .changed(name, b, a) = WitnessMatch.diff(before: before, after: after) else {
            return XCTFail("an identifier-encoded readout flip must be .changed")
        }
        XCTAssertEqual(name, "ScrollArea")
        XCTAssertEqual(b, "StandardInputView;value:0")
        XCTAssertEqual(a, "StandardInputView;value:789")
    }

    // MARK: ClickVerdict.decide

    func testSelfValueChangeWinsWithoutWitness() {
        let r = ClickVerdict.decide(selfBefore: "0", readback: .present(value: "1"),
                                    witnessDiff: .none)
        guard case let .verified(ev, witness) = r else { return XCTFail("self change verifies") }
        XCTAssertNil(witness)
        XCTAssertTrue(ev.contains("0"))
        XCTAssertTrue(ev.contains("1"))
    }

    func testConfirmedGoneVerifies() {
        // Absent across TWO reads (settle-confirmed) is real structural evidence.
        let r = ClickVerdict.decide(selfBefore: nil, readback: .goneConfirmed,
                                    witnessDiff: .none)
        guard case let .verified(ev, witness) = r else { return XCTFail("confirmed gone verifies") }
        XCTAssertNil(witness)
        XCTAssertTrue(ev.contains("confirmed"))
    }

    func testUnconfirmedGoneDoesNotVerifyOnItsOwn() {
        // A SINGLE missed read is indistinguishable from flaky/cold AX reads, so
        // it must NOT, by itself, become VERIFIED — this is the headline
        // false-VERIFIED fix. With no witness it stays DISPATCHED.
        let r = ClickVerdict.decide(selfBefore: nil, readback: .goneUnconfirmed,
                                    witnessDiff: .none)
        XCTAssertEqual(r, .dispatched, "a single refind miss is not proof of a world change")
    }

    func testUnconfirmedGoneMayRideOnAWitness() {
        // An unconfirmed miss can still be VERIFIED if an independent witness
        // changed — the witness is the real evidence, not the absence.
        let r = ClickVerdict.decide(selfBefore: nil, readback: .goneUnconfirmed,
                                    witnessDiff: .changed(name: "display", before: "0", after: "7"))
        guard case let .verified(_, witness) = r else {
            return XCTFail("a corroborating witness verifies even on an unconfirmed miss")
        }
        XCTAssertEqual(witness?.name, "display")
    }

    func testNowDisabledVerifiesWithHonestEvidence() {
        // A control that disabled itself is a REAL observed change — reported as
        // "now disabled", not the misleading "no longer present".
        let r = ClickVerdict.decide(selfBefore: "Submit", readback: .disabled,
                                    witnessDiff: .none)
        guard case let .verified(ev, witness) = r else { return XCTFail("now-disabled verifies") }
        XCTAssertNil(witness)
        XCTAssertTrue(ev.contains("disabled"))
        XCTAssertFalse(ev.contains("no longer present"),
                       "disabled must not masquerade as a disappearance")
    }

    func testPresentUnchangedStaysDispatched() {
        // Still present, same value, no witness → honest under-claim.
        let r = ClickVerdict.decide(selfBefore: "0", readback: .present(value: "0"),
                                    witnessDiff: .none)
        XCTAssertEqual(r, .dispatched)
    }

    func testWitnessChangePromotesPlainButton() {
        // The headline M2 case: a plain button (no self value, still present)
        // becomes VERIFIED because a sibling witness changed.
        let r = ClickVerdict.decide(selfBefore: nil, readback: .present(value: nil),
                                    witnessDiff: .changed(name: "display", before: "0", after: "789"))
        guard case let .verified(ev, witness) = r else {
            return XCTFail("a witness change must promote to verified")
        }
        XCTAssertEqual(witness?.name, "display")
        XCTAssertEqual(witness?.before, "0")
        XCTAssertEqual(witness?.after, "789")
        XCTAssertTrue(ev.contains("display"))
    }

    func testNoSelfNoWitnessStaysDispatched() {
        let r = ClickVerdict.decide(selfBefore: nil, readback: .present(value: nil),
                                    witnessDiff: .none)
        XCTAssertEqual(r, .dispatched)
    }

    func testAmbiguousWitnessStaysDispatched() {
        // 2+ witnesses changed → we do NOT verify (under-claim, never guess).
        let r = ClickVerdict.decide(selfBefore: nil, readback: .present(value: nil),
                                    witnessDiff: .ambiguous(["display", "clock"]))
        XCTAssertEqual(r, .dispatched)
    }

    func testSelfChangePreferredOverWitness() {
        // When the pressed element itself changed, that is the evidence — no
        // need to (and we don't) attribute to a witness.
        let r = ClickVerdict.decide(selfBefore: "off", readback: .present(value: "on"),
                                    witnessDiff: .changed(name: "x", before: "1", after: "2"))
        guard case let .verified(_, witness) = r else { return XCTFail("self change verifies") }
        XCTAssertNil(witness, "self-evidence should not be attributed to a witness")
    }
}
