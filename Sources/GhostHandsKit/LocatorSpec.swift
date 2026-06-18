import Foundation

/// The caller's EXPLICIT disambiguation intent for a named-control lookup —
/// parsed ONCE from the CLI flags and threaded through the resolve verbs.
///
/// HONESTY: these are OPT-IN refinements that let the CALLER state which of
/// several matching controls they mean. They NEVER make the tool silently
/// guess: the no-flag default (`.none`) leaves the refuse-on-ambiguous guarantee
/// byte-for-byte intact, and `--nth` out of range REFUSES rather than clamping
/// to an arbitrary control. `--role` / `--text` only NARROW the candidate set;
/// after they apply, an ambiguous remainder is STILL refused unless the caller
/// also pinned an index with `--nth`.
public struct LocatorSpec: Sendable, Equatable {
    /// Restrict candidates to this exact AX role (e.g. "AXButton"). Compared
    /// case-INSENSITIVELY so `--role axbutton` and `--role AXButton` agree.
    public var role: String?
    /// Restrict candidates to those whose label/value CONTAINS this substring
    /// (case-insensitive), checked against the same primary text fields the
    /// name match reads (title / identifier / value / roleDescription /
    /// descriptionText). A NARROWER hook than the name itself.
    public var text: String?
    /// Pick the i-th surviving candidate (0-based, in the deterministic tree
    /// order `candidateMatches` returns). This is the EXPLICIT tie-break — the
    /// only flag that resolves an ambiguity to a single control. Out of range
    /// REFUSES (`locatorIndexOutOfRange`), never wraps or clamps.
    ///
    /// COUNT SEMANTICS (honesty caveat): `--nth` indexes the RAW survivor list
    /// — it bypasses `NameMatch.resolve`'s identity-collapse, so duplicate-render
    /// twins (the same control rendered in two AXWindow subtrees) are NOT folded
    /// into one. A name the no-flag path reports as `ambiguous — K control(s)`
    /// (twins collapsed) can therefore expose MORE than K valid `--nth` indices,
    /// and a refused `--nth` quotes that raw survivor count, which may exceed the
    /// number of DISTINCT controls a user perceives. This is deliberate: `--nth`
    /// is the escape hatch for picking AMONG twins. The index is also a snapshot,
    /// not a stable id — a re-snapshot after any UI change can renumber survivors.
    public var nth: Int?

    public init(role: String? = nil, text: String? = nil, nth: Int? = nil) {
        self.role = role
        self.text = text
        self.nth = nth
    }

    /// No disambiguators given — the default. When this is the spec, resolution
    /// is byte-for-byte the pre-flag behavior (refuse-on-ambiguous intact).
    public static let none = LocatorSpec()

    /// True iff NO disambiguator was supplied. The resolve path checks this to
    /// guarantee the no-flag route is identical to today (it bypasses `refine`
    /// entirely and calls the original `NameMatch.resolve`).
    public var isEmpty: Bool { role == nil && text == nil && nth == nil }
}

/// The PURE, AX-free locator refinement — the unit-testable core. Given the
/// already-name-matched candidates (built by `Finder.candidateMatches`, the
/// bounded/cycle-safe search) plus the caller's `LocatorSpec`, decide which
/// single candidate (if any) the caller pinned.
///
/// Pipeline (each step is the caller stating intent, never a silent guess):
///   1. `--role` filter — keep only candidates whose role matches (case-insensitive).
///   2. `--text` filter — keep only candidates whose label/value contains the substring.
///   3. `--nth`  pick   — take the i-th SURVIVOR in tree order; out of range → REFUSE.
///   4. no `--nth` → fall through to the EXISTING `NameMatch.resolve` over the
///      survivors, which STILL refuses on >1 distinct control.
public enum Locator {
    /// The outcome of refining a candidate list with a `LocatorSpec`.
    public enum Refined: Equatable {
        /// Exactly one candidate is pinned — its index INTO THE ORIGINAL
        /// `candidates` array (so the caller can fetch the live element pair).
        case one(Int)
        /// More than one distinct control survives the filters and no `--nth`
        /// was given — refuse, carrying the human labels (same shape as
        /// `NameMatch.Resolution.ambiguous`).
        case ambiguous([String])
        /// Nothing survives the filters (or the input was empty) — not found.
        case none
        /// `--nth <i>` was given but `i` is outside `0 ..< survivors.count` —
        /// REFUSE. Carries the requested index and the surviving count so the
        /// caller can report "asked for #i of N".
        case indexOutOfRange(requested: Int, count: Int)
    }

    /// Does this candidate's role match `--role` (case-insensitive)? A nil role
    /// on the candidate can never match a requested role.
    static func roleMatches(_ facts: ElementFacts, _ wanted: String) -> Bool {
        guard let role = facts.role else { return false }
        return role.caseInsensitiveCompare(wanted) == .orderedSame
    }

    /// Does this candidate's label/value CONTAIN `--text` (case-insensitive)?
    /// Checks the same primary text fields `NameMatch.matches` reads, so the
    /// substring filter is consistent with what the name match sees.
    static func textMatches(_ facts: ElementFacts, _ needle: String) -> Bool {
        let n = needle.lowercased()
        for field in [facts.title, facts.identifier, facts.value,
                      facts.roleDescription, facts.descriptionText] {
            if let field, field.lowercased().contains(n) { return true }
        }
        return false
    }

    /// A human label for one candidate, matching the `NameMatch.resolve`
    /// ambiguity-label shape ("<title|id|value> [<role>]") so a refined-but-
    /// still-ambiguous refuse reads identically to the no-flag one.
    static func label(_ facts: ElementFacts) -> String {
        let name = facts.title ?? facts.identifier ?? facts.value ?? "?"
        return "\(name) [\(facts.role ?? "?")]"
    }

    /// PURE refinement (no AX). `candidates` is in deterministic tree order.
    /// `query` is the original name, used ONLY to re-run `NameMatch.resolve` on
    /// the survivors when no `--nth` is given (so exact-over-substring +
    /// identity-collapse still apply to the filtered pool).
    ///
    /// Indices in the result are INTO THE ORIGINAL `candidates` array.
    public static func refine(_ candidates: [ElementFacts], query: String,
                              role: String?, text: String?, nth: Int?) -> Refined {
        // Survivors carry their ORIGINAL index so a `--nth` pick / a fall-through
        // resolve can be mapped back to the live element pair the caller holds.
        var survivors: [Int] = Array(candidates.indices)
        if let role {
            survivors = survivors.filter { roleMatches(candidates[$0], role) }
        }
        if let text {
            survivors = survivors.filter { textMatches(candidates[$0], text) }
        }

        guard !survivors.isEmpty else { return .none }

        // `--nth` is the EXPLICIT tie-break: take the i-th survivor in tree order.
        // Out of range REFUSES — never wrap, never clamp (the honesty gate).
        if let nth {
            guard nth >= 0, nth < survivors.count else {
                return .indexOutOfRange(requested: nth, count: survivors.count)
            }
            return .one(survivors[nth])
        }

        // No `--nth`: the filters only NARROWED the set. Hand the survivors to the
        // EXISTING ambiguity logic, which STILL refuses on >1 distinct control —
        // the refuse-on-ambiguous guarantee is preserved even with --role/--text.
        let survivingFacts = survivors.map { candidates[$0] }
        switch NameMatch.resolve(survivingFacts, query: query) {
        case let .unique(localIndex):
            return .one(survivors[localIndex])
        case let .ambiguous(labels):
            return .ambiguous(labels)
        case .none:
            return .none
        }
    }
}
