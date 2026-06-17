import Foundation

/// Effect-witness logic — the M2 honesty upgrade for `click`.
///
/// A plain button (an `AXButton` like Calculator's "7") has no `AXValue` of its
/// own and is still present after a press, so reading the PRESSED element back
/// can only ever say DISPATCHED-UNVERIFIED. But the press DID change the world:
/// the calculator DISPLAY (a value-bearing sibling) went `0 → 7`. A witness is
/// such a sibling — a value-bearing element in the SAME window subtree whose
/// `AXValue` we snapshot before and after the press.
///
/// This file holds ONLY the pure diff (fabricated facts in, verdict out) so the
/// false-positive scoping can be unit-tested with no live app. The AX walk that
/// collects witnesses lives in `Click.swift`.
public enum WitnessMatch {
    /// One value-bearing element observed for change across a press.
    ///
    /// `key` excludes the value on purpose — the value is the thing that
    /// changes, so keying on it would make every changed element look like
    /// "gone + new" instead of "same element, new value". Key on stable
    /// identity (role + title + identifier + an optional positional tiebreak).
    public struct Witness: Sendable, Equatable {
        public let key: String      // stable identity, value EXCLUDED
        public let name: String     // human label for evidence (role/title/id)
        public let value: String?   // the AXValue at snapshot time

        public init(key: String, name: String, value: String?) {
            self.key = key
            self.name = name
            self.value = value
        }
    }

    /// The verdict of diffing the witness set before vs after a press.
    public enum Verdict: Sendable, Equatable {
        /// Exactly one witness changed — strong, attributable evidence. Carries
        /// the witness name and its before → after so the claim is auditable.
        case changed(name: String, before: String?, after: String?)
        /// No witness changed — honest DISPATCHED-UNVERIFIED (under-claim).
        case none
        /// Two or more witnesses changed at once — we cannot attribute the
        /// effect to our press (a live clock + the display both moved), so we
        /// DEMOTE to unverified rather than guess. The safe direction.
        case ambiguous([String])
    }

    /// The observable "readout" of a value-bearing element — the displayed
    /// string we watch for change. Standard controls expose it as `AXValue`;
    /// some macOS views carry the live value elsewhere (the modern Calculator
    /// display is an `AXScrollArea` whose `AXIdentifier` reads
    /// `StandardInputView;value:5`, with a nil `AXValue`). We observe the first
    /// non-empty of value → identifier → description so a real on-screen change
    /// is witnessed regardless of which attribute the app chose — reading only
    /// the raw string, never parsing app-specific semantics. The element's
    /// IDENTITY key (see `Finder.collectWitnesses`) deliberately excludes all
    /// three of these sources, since any of them may be the thing that changes.
    public static func readout(value: String?, identifier: String?, description: String?) -> String? {
        for candidate in [value, identifier, description] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// Pure diff: pair witnesses by `key`, find which changed value.
    ///
    /// - A witness present before and after with a different value → changed.
    /// - A witness that DISAPPEARED (before-only) is NOT counted: the click's
    ///   own target-gone check already covers structural change, and a vanished
    ///   sibling is not an observed value flip we can quote.
    /// - A witness that APPEARED (after-only) is likewise not a value change.
    /// - A witness whose key is NOT UNIQUE within its own side (before or after)
    ///   is dropped entirely: two distinct elements sharing a key (e.g. two
    ///   untitled `AXStaticText` with nil frames → identical `key`) cannot be
    ///   reliably paired, so a value mismatch between them would be a FABRICATED
    ///   before→after that no real element underwent. A non-unique key can never
    ///   be attributable evidence, so it is excluded rather than guessed — the
    ///   safe direction (under-claim, never over-claim).
    /// - Exactly one change → `.changed`; zero → `.none`; two or more →
    ///   `.ambiguous` (demote, never over-claim).
    public static func diff(before: [Witness], after: [Witness]) -> Verdict {
        // Only keys that occur EXACTLY ONCE on a side can be paired there; a key
        // seen 2+ times within either set is ambiguous-by-construction and must
        // not be diffed (it would invent a before→after across two siblings).
        let uniqueBefore = uniqueKeys(before)
        let uniqueAfter = uniqueKeys(after)

        var afterByKey: [String: Witness] = [:]
        for w in after where uniqueAfter.contains(w.key) { afterByKey[w.key] = w }

        var changes: [(name: String, before: String?, after: String?)] = []
        for b in before where uniqueBefore.contains(b.key) {
            guard let a = afterByKey[b.key] else { continue } // disappeared / un-pairable — not a value flip
            if a.value != b.value {
                changes.append((name: a.name, before: b.value, after: a.value))
            }
        }

        switch changes.count {
        case 0:
            return .none
        case 1:
            let c = changes[0]
            return .changed(name: c.name, before: c.before, after: c.after)
        default:
            return .ambiguous(changes.map(\.name))
        }
    }

    /// Keep only witnesses that have SETTLED — present with the SAME value across
    /// two post-press reads. A press causes a result to settle to a new value
    /// (read1 == read2); an element changing for an UNRELATED reason — a live
    /// clock, an animation, a debounced/relative-time label, a scroll in flight —
    /// keeps moving (read1 != read2) and is dropped. This is the causation fence:
    /// the witness diff proves only correlation, so we additionally require the
    /// post-press value to be quiescent before we will quote it as evidence. A
    /// key that is non-unique on either read is also dropped (un-pairable).
    public static func stable(_ after1: [Witness], _ after2: [Witness]) -> [Witness] {
        let u1 = uniqueKeys(after1)
        let u2 = uniqueKeys(after2)
        var byKey2: [String: Witness] = [:]
        for w in after2 where u2.contains(w.key) { byKey2[w.key] = w }
        return after1.filter { u1.contains($0.key) && byKey2[$0.key]?.value == $0.value }
    }

    /// The set of keys that appear EXACTLY ONCE in `witnesses`. A key seen more
    /// than once identifies elements that collide on identity (a key collision),
    /// so it cannot be used to pair a specific before with a specific after.
    private static func uniqueKeys(_ witnesses: [Witness]) -> Set<String> {
        var counts: [String: Int] = [:]
        for w in witnesses { counts[w.key, default: 0] += 1 }
        return Set(counts.compactMap { $0.value == 1 ? $0.key : nil })
    }
}
