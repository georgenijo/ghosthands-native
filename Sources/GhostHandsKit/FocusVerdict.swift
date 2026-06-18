import Foundation

/// The pure verdict for the `focus` verb — honest about whether the control is
/// OBSERVED to hold keyboard focus after the set, or merely that AX accepted the
/// `AXFocused = true` dispatch.
///
/// The contract mirrors `ValueVerdict`: this decider NEVER sees the `setValue`
/// boolean. A `setValue(true, forAttribute: AXFocused)` returning `true` is only
/// a DISPATCH — it is NOT proof the control now has focus. The app may refuse or
/// silently drop the focus request while AX still reports `.success`. The SOLE
/// arbiter is the AXFocused attribute READ BACK off a fresh tree:
/// - reads back `true`  → VERIFIED (the control is observed focused),
/// - reads back `false` → DISPATCHED-UNVERIFIED (accepted, but not focused),
/// - reads back `nil`   → DISPATCHED-UNVERIFIED (AXFocused is unreadable /
///   unsettable on this control — we cannot witness focus, so we never claim it).
///
/// Kept pure (no AX) so the "false/nil never verifies" guard is hermetically
/// testable on a fabricated read-back Bool — never a live app.
public enum FocusVerdict {
    public enum Result: Sendable, Equatable {
        /// AXFocused read back `true` — the control is OBSERVED to hold focus.
        /// `evidence` is the human string (always quotes the focused read-back).
        case verified(evidence: String)
        /// AX accepted the focus set (setValue true / no throw) but AXFocused did
        /// NOT read back true (false, or unreadable/unsettable nil) — honest
        /// under-claim, never a focus claim we cannot observe.
        case dispatched
    }

    /// Decide the verdict from the AXFocused read-back ALONE.
    ///
    /// - `focusedAfter`: the AXFocused attribute re-read off a FRESH tree.
    ///   `true` = observed focused, `false` = observed NOT focused, `nil` =
    ///   AXFocused not readable on this control (so focus is unwitnessable).
    ///
    /// Only `true` carries a claim. Both `false` and `nil` demote to DISPATCHED —
    /// the safe direction: we never assert focus we cannot read back as true.
    public static func decide(focusedAfter: Bool?) -> Result {
        if focusedAfter == true {
            return .verified(evidence: "AXFocused → true")
        }
        return .dispatched
    }
}
