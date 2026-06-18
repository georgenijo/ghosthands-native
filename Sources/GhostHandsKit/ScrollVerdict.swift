import CoreGraphics
import Foundation

/// The PURE honesty core of the SCROLL verb — no AX, no CGEvent, no live app.
///
/// A scroll has an honest, readable witness the pixel tier lacks: an
/// `AXScrollArea` exposes a vertical / horizontal `AXScrollBar` whose `AXValue`
/// is the NORMALISED scroll position (0.0 at the top/left, 1.0 at the
/// bottom/right). We snapshot that fraction BEFORE acting and re-read it AFTER:
///
///   - the position MOVED  → VERIFIED (an observed world-change),
///   - the position is UNCHANGED → DISPATCHED-UNVERIFIED — the event was
///     accepted but nothing observable moved (already at the boundary, or no
///     readable scroll bar). This is the load-bearing honesty rule: a scroll
///     already pinned at the end that cannot move further is DISPATCHED, NEVER a
///     fabricated success.
///
/// Everything here is a function of plain values (a before / after fraction, a
/// parsed direction + amount) so the whole VERIFIED/DISPATCHED decision and the
/// CLI parse are unit-testable on FABRICATED facts — a live scroll area NEVER
/// appears in a test.
public enum ScrollVerdict {
    /// The minimum change in the normalised scroll position (0.0…1.0) that counts
    /// as an OBSERVED move. A small but non-zero floor so AX read jitter / a
    /// sub-pixel rounding in the reported fraction cannot fabricate a "verified";
    /// a real one-line/one-page scroll moves the bar well above this.
    public static let defaultEpsilon = 0.0005

    public enum Result: Sendable, Equatable {
        /// The scroll position moved by `delta` (>= epsilon). An observed
        /// world-change. Honest VERIFIED. Carries before/after so the claim is
        /// auditable (e.g. "0.00 → 0.18").
        case verified(before: Double, after: Double)
        /// The scroll was dispatched but the position did not move enough to prove
        /// an effect — honest under-claim, NEVER reported as success. `observable`
        /// is false when we had no readable scroll-bar value to compare at all
        /// (acted, could not look), true when we read a value that simply did not
        /// move (already at the boundary).
        case dispatched(observable: Bool)
    }

    /// Decide the verdict from a BEFORE and AFTER scroll-bar fraction.
    ///
    /// - `before`/`after` nil ⇒ we could not READ a scroll-bar value, so we cannot
    ///   observe a move: DISPATCHED-UNVERIFIED with `observable == false` (acted,
    ///   could not look) — never a claim.
    /// - both readable and the absolute delta >= epsilon ⇒ VERIFIED.
    /// - both readable and the delta < epsilon ⇒ DISPATCHED with
    ///   `observable == true` (we looked; the bar did not move — already at the
    ///   boundary, or the app ignored the scroll).
    ///
    /// This is the single source of the scroll honesty decision — the live verb
    /// drives it with the REAL read-back fractions, never a hardcoded literal.
    public static func decide(before: Double?, after: Double?,
                              epsilon: Double = defaultEpsilon) -> Result {
        guard let before, let after else { return .dispatched(observable: false) }
        if abs(after - before) >= epsilon {
            return .verified(before: before, after: after)
        }
        return .dispatched(observable: true)
    }
}

/// The PURE identity + resolution core for a scroll CONTAINER — no AX, no live
/// app, decided on FABRICATED facts so the `--in <name>` ambiguity refuse and
/// the before/after SAME-CONTAINER guard are unit-testable without a real
/// scroll area.
///
/// Two honesty rules ride here, both mirroring the established control-name
/// resolution (`NameMatch`):
///   - `--in <name>` that matches MORE THAN ONE distinct scroll area is
///     AMBIGUOUS — refuse rather than silently scroll an arbitrary `.first`
///     (a wrong-target risk), exactly as `click` refuses on `.ambiguousMatch`.
///   - the after-witness must read the SAME container the before-witness read;
///     if a mid-action re-resolution lands on a DIFFERENT scroll area, the
///     before/after fractions come from different bars and a fabricated delta
///     is possible. `sameContainer` keys on stable structure so the live verb
///     can demote to "unobservable" rather than quote a cross-container delta.
public enum ScrollAreaMatch {
    /// The stable, value-free facts that identify a scroll area for matching and
    /// for the same-container guard. Pure values — built from a live `Element` at
    /// the one AX-touching call site, decided here without AX.
    public struct Facts: Sendable, Equatable {
        public var title: String?
        public var identifier: String?
        public var roleDescription: String?
        /// The on-screen frame rounded to whole points, as an identity key
        /// component (a scroll area does not move between the two reads of one
        /// actuation; a different area at a different place is a different key).
        public var frame: CGRect?

        public init(title: String? = nil, identifier: String? = nil,
                    roleDescription: String? = nil, frame: CGRect? = nil) {
            self.title = title
            self.identifier = identifier
            self.roleDescription = roleDescription
            self.frame = frame
        }
    }

    /// A stable identity key for ONE scroll area — structural only (title +
    /// identifier + role-description + rounded frame). Used both to collapse
    /// duplicate-render twins into one logical container for the ambiguity count
    /// and to compare the before/after container for the same-container guard.
    public static func identityKey(_ f: Facts) -> String {
        let frameKey = f.frame.map {
            "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())),"
                + "\(Int($0.width.rounded())),\(Int($0.height.rounded()))"
        } ?? ""
        return [f.title ?? "", f.identifier ?? "", f.roleDescription ?? "", frameKey]
            .joined(separator: "\u{1}")
    }

    /// True iff two scroll-area facts denote the SAME logical container (same
    /// identity key). The live verb's after-witness uses this to refuse quoting a
    /// delta read off a DIFFERENT area than the before-witness.
    public static func sameContainer(_ a: Facts, _ b: Facts) -> Bool {
        identityKey(a) == identityKey(b)
    }

    /// The resolution of a `--in <name>` selector over the role-gated scroll-area
    /// candidates (already filtered to AXScrollArea and name-matched upstream).
    public enum Resolution: Equatable {
        case unique(Int)            // index into the candidates passed in
        case ambiguous([String])    // human labels of the distinct candidates
        case none
    }

    /// Resolve `--in` candidates to a single index, ambiguity, or none. Distinct
    /// scroll areas are grouped by identity; >1 DISTINCT group ⇒ ambiguous
    /// (refuse), exactly like `NameMatch.resolve` for controls — never a silent
    /// `.first`. A label fallback names each distinct candidate for the error.
    public static func resolve(_ candidates: [Facts]) -> Resolution {
        guard !candidates.isEmpty else { return .none }
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for i in candidates.indices {
            let key = identityKey(candidates[i])
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }
        if order.count == 1 { return .unique(groups[order[0]]!.first!) }
        let labels = order.map { key -> String in
            let f = candidates[groups[key]!.first!]
            return f.title ?? f.identifier ?? f.roleDescription ?? "scroll area"
        }
        return .ambiguous(labels)
    }
}

/// The PURE parse of the scroll CLI args — `direction [amount]`.
///
/// Free of IO so direction/amount parsing is unit-testable with no CLI run,
/// mirroring `PixelFlags`/`KeySpec`. The `--in <name>` / `--visible` flags are
/// scanned out by the CLI's flag loop (reusing the same in-any-order pattern as
/// the other verbs); what remains is `<app> <direction> [amount]`, and this
/// parser validates the `<direction> [amount]` tail.
public enum ScrollSpec {
    /// A scroll AXIS + sign. `up`/`down` drive the VERTICAL scroll bar; `left`/
    /// `right` drive the HORIZONTAL one. The sign is the direction the CONTENT
    /// moves toward: `down`/`right` increase the scroll-bar fraction (toward 1.0),
    /// `up`/`left` decrease it (toward 0.0).
    public enum Direction: String, Sendable, Equatable, CaseIterable {
        case up, down, left, right

        /// True for the vertical axis (up/down); false for horizontal (left/right).
        public var isVertical: Bool { self == .up || self == .down }
        /// The sign of the scroll-bar fraction change: +1 toward 1.0 (down/right),
        /// -1 toward 0.0 (up/left). Used to drive an AX scroll-bar SET when the bar
        /// is settable, and to sign the CGEvent wheel delta.
        public var sign: Double { (self == .down || self == .right) ? 1 : -1 }

        /// The human label of the known directions, for the usage/error string.
        public static let known = Direction.allCases.map(\.rawValue).joined(separator: " | ")
    }

    /// The default scroll magnitude when `[amount]` is omitted: ONE page. A page
    /// is the sane "scroll the visible area" unit (PageDown/PageUp), and it maps
    /// cleanly to a wheel delta and to an AX scroll-bar fraction step.
    public static let defaultAmount = 1.0

    public struct Parsed: Sendable, Equatable {
        public let direction: Direction
        /// The number of pages to scroll (defaults to `defaultAmount`). Always
        /// positive; the DIRECTION carries the sign.
        public let amount: Double

        public init(direction: Direction, amount: Double = ScrollSpec.defaultAmount) {
            self.direction = direction
            self.amount = amount
        }
    }

    public enum ParseError: Error, Equatable {
        /// The direction token was not up|down|left|right.
        case badDirection(String)
        /// The amount token did not parse as a positive number.
        case badAmount(String)
    }

    /// Parse `<direction> [amount]`. The amount, when present, must be a POSITIVE
    /// number (a magnitude — the direction carries the sign); a zero / negative /
    /// non-numeric amount is a refuse (we won't guess). An absent amount defaults
    /// to one page.
    public static func parse(direction rawDir: String, amount rawAmount: String?) throws -> Parsed {
        guard let dir = Direction(rawValue: rawDir.lowercased()) else {
            throw ParseError.badDirection(rawDir)
        }
        guard let rawAmount else { return Parsed(direction: dir) }
        guard let amount = Double(rawAmount), amount > 0 else {
            throw ParseError.badAmount(rawAmount)
        }
        return Parsed(direction: dir, amount: amount)
    }
}
