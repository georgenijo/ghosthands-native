import XCTest
@testable import GhostHandsKit

/// Hermetic — the M3 honesty surface for `type` / `set-value`, with FABRICATED
/// before/after/intended strings (no live app). The single most important
/// invariant under test: a value that READ BACK UNCHANGED is NEVER verified, no
/// matter what the (here, implicit) setValue boolean was — this is the
/// structural prevention of the cardinal sin (setValue==true faking success).
final class ValueVerdictTests: XCTestCase {
    private func decide(_ before: String?, _ after: String?, _ intended: String,
                        witness: WitnessMatch.Verdict = .none) -> ValueVerdict.Result {
        ValueVerdict.decide(before: before, after: after, intended: intended,
                            witnessDiff: witness)
    }

    // MARK: the no-op trap (the cardinal sin) — unchanged must NEVER verify

    func testUnchangedValueIsDispatchedNeverVerified() {
        // AX accepted the set (the caller already checked setValue==true) but the
        // field reads back exactly as before — the no-op. MUST be dispatched.
        XCTAssertEqual(decide("old", "old", "new"), .dispatched)
    }

    func testUnchangedEmptyFieldIsDispatched() {
        // Set "hello" into an empty field that stays empty → no observed change.
        XCTAssertEqual(decide(nil, nil, "hello"), .dispatched)
    }

    func testUnchangedEmptyTreatsBlankAsNil() {
        // "" and nil are the same observable (a blank field) — no change.
        XCTAssertEqual(decide(nil, "", "x"), .dispatched)
        XCTAssertEqual(decide("", nil, "x"), .dispatched)
    }

    // MARK: clean atomic set — exact read-back

    func testExactMatchVerifiedExact() {
        guard case let .verified(evidence, exact, witness) = decide(nil, "hello", "hello") else {
            return XCTFail("after == intended must verify")
        }
        XCTAssertTrue(exact)
        XCTAssertNil(witness)
        XCTAssertEqual(evidence, "value nil → \"hello\"")
    }

    func testExactMatchOverAPriorValue() {
        guard case let .verified(_, exact, _) = decide("old", "new", "new") else {
            return XCTFail("after == intended must verify even with a prior value")
        }
        XCTAssertTrue(exact)
    }

    // MARK: normalisation / partial — verified-with-caveat, exact:false, quoted

    func testNormalisedChangeVerifiedButNotExact() {
        // App lowercased "JOHN" → "john": a real observed change of THIS control,
        // verified, but exact:false and the literal before→after is quoted so the
        // human sees the normalisation.
        guard case let .verified(evidence, exact, _) = decide(nil, "john", "JOHN") else {
            return XCTFail("a normalised commit is still an observed change → verified")
        }
        XCTAssertFalse(exact)
        XCTAssertEqual(evidence, "value nil → \"john\"")
    }

    func testPartialPrefixCommitVerifiedNotExact() {
        // App reformatted "5" → "$5.00": intended is contained in after → toward.
        guard case let .verified(_, exact, _) = decide(nil, "$5.00", "5") else {
            return XCTFail("a partial/normalised commit toward intended must verify")
        }
        XCTAssertFalse(exact)
    }

    func testChangedToSomethingElseStillVerifiedAsObservedChange() {
        // The field changed but to a value unrelated to intended. It is still an
        // OBSERVED change of this exact control, so we verify and QUOTE it (the
        // human judges) — we never silently assert it equals intended.
        guard case let .verified(evidence, exact, _) = decide("a", "zzz", "b") else {
            return XCTFail("any real change of the same control is observed evidence")
        }
        XCTAssertFalse(exact)
        XCTAssertEqual(evidence, "value \"a\" → \"zzz\"")
    }

    // MARK: witness fallback for opaque controls

    func testUnchangedSelfRidesOnWitnessChange() {
        // The control's own value did not move, but a scoped sibling readout did
        // → verified by witness, witness triple carried for auditability.
        let w = WitnessMatch.Verdict.changed(name: "status", before: "off", after: "on")
        guard case let .verified(evidence, exact, witness) = decide("x", "x", "y", witness: w) else {
            return XCTFail("an opaque control with a changed sibling witness verifies")
        }
        XCTAssertFalse(exact)
        XCTAssertEqual(witness?.name, "status")
        XCTAssertEqual(evidence, "status \"off\" → \"on\"")
    }

    func testUnchangedSelfWithAmbiguousWitnessStaysDispatched() {
        // Two siblings moved — cannot attribute → demote (the safe direction).
        let w = WitnessMatch.Verdict.ambiguous(["a", "b"])
        XCTAssertEqual(decide("x", "x", "y", witness: w), .dispatched)
    }

    // MARK: checkbox 0 → 1 (the set-value boolean read-back)

    func testCheckboxZeroToOneVerified() {
        guard case let .verified(evidence, exact, _) = decide("0", "1", "1") else {
            return XCTFail("a checkbox flipping 0 → 1 to the intended state must verify")
        }
        XCTAssertTrue(exact)
        XCTAssertEqual(evidence, "value \"0\" → \"1\"")
    }

    func testCheckboxAlreadyCheckedIsDispatchedNotVerified() {
        // Request "set checked" on an already-checked box → no change → NOT a
        // success (the 'already in requested state' no-op).
        XCTAssertEqual(decide("1", "1", "1"), .dispatched)
    }

    // MARK: movedToward helper

    func testMovedTowardContainmentBothDirections() {
        XCTAssertTrue(ValueVerdict.movedToward(after: "$5.00", intended: "5"))   // after contains intended
        XCTAssertTrue(ValueVerdict.movedToward(after: "joh", intended: "john"))  // after is prefix of intended
        XCTAssertFalse(ValueVerdict.movedToward(after: "abc", intended: "xyz"))  // unrelated
        XCTAssertFalse(ValueVerdict.movedToward(after: "x", intended: "x"))      // exact is handled elsewhere
        XCTAssertFalse(ValueVerdict.movedToward(after: nil, intended: "x"))      // cleared ≠ progress
        XCTAssertFalse(ValueVerdict.movedToward(after: "", intended: "x"))
    }
}
