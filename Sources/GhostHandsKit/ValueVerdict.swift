import Foundation

/// The pure verdict for a VALUE-SETTING verb (`type`, `set-value`).
///
/// This is the structural heart of the M3 honesty contract — the code path that
/// PREVENTS the cardinal sin: a `setValue()` call returning `true` masquerading
/// as success. `setValue==true` means the AX layer *dispatched* the set; it is
/// NEVER, by itself, proof that the field now holds the value. The app's model
/// may reject or normalise the write while AX still reports `.success`.
///
/// So this verdict NEVER sees the `setValue` boolean. It sees only the value
/// the control READ BACK as (`after`) off a FRESH snapshot, the value BEFORE,
/// and the value we INTENDED. The read-back is the sole arbiter:
/// - `after == intended` (after peeling) → VERIFIED (clean atomic set),
/// - `after != before` and the field moved TOWARD intended (a non-empty
///   prefix/substring of, or normalisation of, the target) → VERIFIED, but the
///   literal before → after is quoted so the human sees the normalisation,
/// - `after == before` (no observed change) → DISPATCHED-UNVERIFIED (the no-op
///   trap: AX accepted the set but the world did not move),
/// - it can also ride the M2 witness path (a sibling readout changed) when the
///   control's own value is opaque.
///
/// Kept pure (no AX) so the no-op-fakes-success guard is hermetically testable
/// on fabricated before/after/intended strings — never a live app.
public enum ValueVerdict {
    public enum Result: Sendable, Equatable {
        /// The control's value was OBSERVED to hold (or move toward) the intended
        /// value. `evidence` is the human string (always quotes before → after).
        /// `exact` is true when `after == intended` precisely, false when it was
        /// a "changed toward" promotion (normalisation/partial) — so the caller
        /// can phrase the report with the right confidence.
        case verified(evidence: String, exact: Bool,
                      witness: (name: String, before: String?, after: String?)?)
        /// AX accepted (setValue true / no throw) but the read-back shows NO
        /// observable change — honest under-claim, never a success claim.
        case dispatched

        public static func == (lhs: Result, rhs: Result) -> Bool {
            switch (lhs, rhs) {
            case let (.verified(e1, x1, w1), .verified(e2, x2, w2)):
                return e1 == e2 && x1 == x2 && w1?.name == w2?.name
                    && w1?.before == w2?.before && w1?.after == w2?.after
            case (.dispatched, .dispatched): return true
            default: return false
            }
        }
    }

    /// Whether `after` is a recognisable move TOWARD `intended` (without being
    /// exactly equal). Case-insensitive containment in EITHER direction covers
    /// the two common normalisations: the app appended/prefixed (set "5", field
    /// shows "$5.00" → intended is contained in after) OR the app truncated/
    /// reformatted (set a long string, field shows a clipped form → after is
    /// contained in intended). Requires `after` non-empty so a field that merely
    /// CLEARED is not mistaken for progress toward a non-empty target.
    public static func movedToward(after: String?, intended: String) -> Bool {
        guard let after, !after.isEmpty, !intended.isEmpty else { return false }
        let a = after.lowercased()
        let t = intended.lowercased()
        if a == t { return false }              // exact is handled separately
        return a.contains(t) || t.contains(a)
    }

    /// Decide the verdict from the read-back facts ALONE.
    ///
    /// - `before`  : the control's value before the set (nil = empty/unreadable).
    /// - `after`   : the control's value re-read off a FRESH tree (nil = empty).
    /// - `intended`: the value we asked AX to set.
    /// - `witnessDiff`: the scoped sibling diff (M2), consulted ONLY when the
    ///   control's own value did not change — exactly the click fallback.
    ///
    /// Order of evidence (each is an OBSERVED change, never the setValue bool):
    /// 1. after == intended → VERIFIED exact,
    /// 2. after != before AND after moved toward intended → VERIFIED (normalised),
    /// 3. after != before (changed, but NOT toward intended — e.g. the app
    ///    rewrote it to something else) → still a real observed change of THIS
    ///    control, reported VERIFIED with the literal before → after so the human
    ///    judges (we never silently assert it equals intended),
    /// 4. after == before → consult the witness; one sibling changed → VERIFIED
    ///    by witness; else DISPATCHED-UNVERIFIED (the no-op).
    public static func decide(before: String?, after: String?, intended: String,
                              witnessDiff: WitnessMatch.Verdict) -> Result {
        let beforeNorm = normalize(before)
        let afterNorm = normalize(after)

        // THE NO-OP GUARD (the cardinal-sin fence). If the control's OWN value
        // did not move, there is NO observed change on it — even if it happens to
        // already equal `intended` (an already-checked box "set" to checked). A
        // setValue==true here is a DISPATCH, never a success. We do NOT verify
        // off the value; the only thing that can still carry a claim is a scoped
        // SIBLING witness (an opaque control whose effect shows elsewhere). This
        // ordering is load-bearing: checking `after == intended` FIRST would
        // wrongly verify a no-op whenever the field was already at the target.
        if afterNorm == beforeNorm {
            if case let .changed(name, wBefore, wAfter) = witnessDiff {
                return .verified(evidence: "\(name) \(quote(wBefore)) → \(quote(wAfter))",
                                 exact: false, witness: (name, wBefore, wAfter))
            }
            return .dispatched
        }

        // The control's own value CHANGED (it is the same control by identity —
        // the caller guarantees that). A real change is observed evidence.
        // - exact when it now literally holds `intended` (clean atomic set),
        // - else verified-with-caveat: quote the literal before → after so a
        //   normalisation ("JOHN" → "john") / partial commit / reformat is
        //   visible and the human judges — we never silently assert equality.
        let exact = (afterNorm == intended)
        return .verified(evidence: "value \(quote(before)) → \(quote(after))",
                         exact: exact, witness: nil)
    }

    /// Treat "" the same as nil — an empty AXValue and an absent one are the same
    /// observable (a blank field). Without this, set "" into an empty field, or
    /// an app that reports "" vs nil inconsistently, would flap.
    static func normalize(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func quote(_ s: String?) -> String {
        guard let s else { return "nil" }
        return s.debugDescription
    }
}
