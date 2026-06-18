import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation

/// The SCROLL ACTUATION tier — `scroll <app> <direction> [amount] [--in <name>] [--visible]`.
///
/// Scrolls a scroll-area / list HONESTLY: it has a real, readable witness the
/// pixel tier lacks. An `AXScrollArea` exposes a vertical / horizontal
/// `AXScrollBar` whose `AXValue` is the NORMALISED scroll position (0.0 at the
/// top/left, 1.0 at the bottom/right). So unlike `click-at` (screenshot diff) or
/// `key` (no observable at all), scroll VERIFIES by reading that fraction before
/// and after the actuation and asking "did the bar move?". (See `ScrollVerdict`.)
///
/// Honesty order:
///   1. Resolve the app, and the scroll CONTAINER — a named `--in <name>` scroll
///      area, else the focused element's enclosing scroll area, else the primary
///      (largest) `AXScrollArea` in the frontmost window. REFUSE (`.noScrollArea`)
///      if no scrollable area is found.
///   2. WITNESS before: read the relevant scroll bar's `AXValue` fraction.
///   3. Actuate: prefer the AX route — SET the scroll-bar `AXValue` directly when
///      the bar is settable (cursor-less, no event posting); else post a CGEvent
///      `scrollWheel` in the direction (invisible `postToPid` by default, the HID
///      tap when `--visible`).
///   4. WITNESS after: re-read the fraction. Moved ⇒ VERIFIED; unchanged ⇒
///      DISPATCHED-UNVERIFIED — already at the boundary, or no observable. A
///      boundary-pinned scroll that cannot move is honestly DISPATCHED, NEVER a
///      fake success.
///
/// INVISIBILITY (the same axis as the pixel/key tiers, reusing `PixelMode`):
///   - `.invisible` (DEFAULT): the AX scroll-bar SET is fully cursor-less; the
///     CGEvent fallback is posted straight to the app's pid (`CGEventPostToPid`)
///     — no warp, no HID tap, background-capable best-effort. `postToPid` is
///     coordinate-only, so some non-AppKit surfaces may ignore the wheel
///     (honestly DISPATCHED-UNVERIFIED).
///   - `.visible` (LABELLED exception): post the wheel through the HID tap
///     (`.cghidEventTap`) so the WindowServer routes it to the window under the
///     point. NOT invisible — may scroll whatever is frontmost under the point.
public struct ScrollOutcome: Sendable, Equatable {
    public let app: String
    /// The scroll container we acted on (its title / role-derived label), for the report.
    public let container: String
    public let direction: ScrollSpec.Direction
    public let amount: Double
    /// The actuation route actually used: "AX scroll-bar set" or "CGEvent wheel".
    public let via: String
    public let dispatched: Bool
    public let verified: Bool
    /// True when we could READ the scroll-bar value (so a no-move is a real
    /// "looked, did not move"); false when no scroll-bar value was readable
    /// (acted, could not look).
    public let observable: Bool
    /// The normalised scroll-bar position before / after, when readable (for the
    /// VERIFIED evidence string). nil when the bar exposed no value.
    public let positionBefore: Double?
    public let positionAfter: Double?
    /// The delivery mode used; `.visible` is surfaced so a non-invisible HID wheel
    /// is LABELLED, never silent.
    public let mode: PixelMode

    public init(app: String, container: String, direction: ScrollSpec.Direction,
                amount: Double, via: String, dispatched: Bool, verified: Bool,
                observable: Bool, positionBefore: Double?, positionAfter: Double?,
                mode: PixelMode = .invisible) {
        self.app = app
        self.container = container
        self.direction = direction
        self.amount = amount
        self.via = via
        self.dispatched = dispatched
        self.verified = verified
        self.observable = observable
        self.positionBefore = positionBefore
        self.positionAfter = positionAfter
        self.mode = mode
    }
}

extension GhostHands {
    /// One wheel "line" of scroll per unit amount, in the CGEvent line unit. A
    /// page ≈ several lines; we translate `amount` pages → lines so a default
    /// (1 page) moves a visible chunk. Tuned to move a typical list/scroll area
    /// without overshooting; the witness verifies the real move regardless.
    static let scrollLinesPerPage = 10

    /// `scroll <app> <direction> [amount] [--in <name>] [--visible]` — scroll a
    /// scroll area / list, cursor-less by default, verified by the scroll-bar
    /// witness.
    ///
    /// Honesty contract (nothing here ever hardcodes success):
    /// - throws `.accessibilityNotTrusted` if AX permission is missing,
    /// - throws `.appNotFound` / `.appAmbiguous` from `Target.resolve`,
    /// - throws `.noScrollArea` if no scrollable area is found (named or primary),
    /// - otherwise returns an outcome that is honest about VERIFIED (the bar moved)
    ///   vs DISPATCHED-UNVERIFIED (accepted, bar did not move / not observable).
    @MainActor
    public static func scroll(appSpec: String, direction: ScrollSpec.Direction,
                              amount: Double = ScrollSpec.defaultAmount,
                              container named: String? = nil,
                              mode: PixelMode = .invisible,
                              settle: TimeInterval = 0.15) throws -> ScrollOutcome {
        // Bootstrap the WindowServer connection (same reason as the pixel tier):
        // CGS / CGEvent calls want it. Stays a background accessory.
        _ = NSApplication.shared

        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        // 1. Resolve the scroll container. A named `--in` wins (and REFUSES on an
        //    ambiguous match, like the other named verbs); else the focused
        //    element's enclosing scroll area; else the primary (largest) scroll
        //    area in the frontmost window. REFUSE if none is scrollable.
        guard let area = try resolveScrollArea(named: named, target: target) else {
            throw GhostHandsError.noScrollArea(app: target.name, named: named)
        }
        let containerLabel = scrollAreaLabel(area)
        // Identity of the container we WITNESS, so the after-read can prove it
        // re-resolved to the SAME area (never quote a cross-container delta).
        let areaIdentity = ScrollAreaMatch.identityKey(scrollAreaFacts(area))

        // The relevant scroll bar for this axis (vertical for up/down, horizontal
        // for left/right). Its AXValue fraction is our witness.
        let bar = scrollBar(of: area, vertical: direction.isVertical)

        // 2. WITNESS before.
        let before = bar.flatMap { scrollBarValue($0) }

        // 3. Actuate. Prefer the AX scroll-bar SET when the bar exposes a settable
        //    AXValue — fully cursor-less, no event posting. Else fall back to a
        //    CGEvent scrollWheel.
        let via: String
        if let bar, let before, trySetScrollBar(bar, before: before, direction: direction,
                                                amount: amount) {
            via = "AX scroll-bar set"
        } else {
            postScrollWheel(in: area, target: target, direction: direction,
                            amount: amount, mode: mode)
            via = "CGEvent wheel"
        }

        if settle > 0 { Thread.sleep(forTimeInterval: settle) }

        // 4. WITNESS after — re-read the bar's fraction off a FRESH handle to the
        //    SAME bar (re-resolve so we never read a stale value). Re-resolution
        //    can land on a DIFFERENT area if the UI mutated mid-action (a focus
        //    shift, a tie in `largestByArea`); if it does, before/after would come
        //    from different bars and the delta would be FABRICATED. Guard on the
        //    container identity: a divergent re-resolution drops `after` to nil so
        //    the verdict honestly demotes to dispatched-unobservable, never quotes
        //    a cross-container delta. (`try?` — a `--in` ambiguity that only
        //    appears on the after-read is a demote, not a hard fail of the action
        //    we already dispatched.)
        // `try?` collapses the throw into Element??; flatten and fall back to the
        // original `area` so a transient nil re-read still re-witnesses the same area.
        let freshArea: Element = ((try? resolveScrollArea(named: named, target: target)) ?? nil) ?? area
        let after: Double?
        if ScrollAreaMatch.identityKey(scrollAreaFacts(freshArea)) == areaIdentity {
            let freshBar = scrollBar(of: freshArea, vertical: direction.isVertical)
            after = freshBar.flatMap { scrollBarValue($0) }
        } else {
            after = nil
        }

        let verdict = ScrollVerdict.decide(before: before, after: after)
        let verified: Bool
        let observable: Bool
        switch verdict {
        case .verified:
            verified = true
            observable = true
        case let .dispatched(obs):
            verified = false
            observable = obs
        }

        return ScrollOutcome(app: target.name, container: containerLabel,
                             direction: direction, amount: amount, via: via,
                             dispatched: true, verified: verified, observable: observable,
                             positionBefore: before, positionAfter: after, mode: mode)
    }

    // MARK: - container resolution

    /// Pure, AX-free identity facts of a scroll area — the bridge from a live
    /// `Element` into `ScrollAreaMatch.Facts` (the one AX-touching step; the
    /// matching/comparison is decided purely). Used for the `--in` ambiguity
    /// refuse and the before/after same-container guard.
    @MainActor
    static func scrollAreaFacts(_ area: Element) -> ScrollAreaMatch.Facts {
        ScrollAreaMatch.Facts(title: area.title(), identifier: area.identifier(),
                              roleDescription: area.roleDescription(), frame: area.frame())
    }

    /// Resolve the scroll area to act on: a named one (`--in`), else the focused
    /// element's enclosing scroll area, else the LARGEST `AXScrollArea` in the
    /// frontmost window (the primary content area). nil ⇒ none found (REFUSE).
    /// Throws `.ambiguousMatch` when `--in` matches more than one DISTINCT scroll
    /// area — refuse rather than scroll an arbitrary one (like the other named verbs).
    @MainActor
    static func resolveScrollArea(named: String?, target: Target) throws -> Element? {
        // A named container: match an AXScrollArea by name, like the other verbs'
        // name resolution but role-gated to scroll areas (a label that merely
        // shares the name is excluded). nil name ⇒ fall through to auto-pick. A
        // substring search can match SEVERAL scroll areas; resolve through
        // `ScrollAreaMatch` so >1 distinct area is AMBIGUOUS (refuse), never a
        // silent `.first`.
        if let named {
            let matches = target.element.searchElements(
                matching: named, options: Self.boundedSearchOptions)
                .filter { $0.role() == "AXScrollArea" }
            switch ScrollAreaMatch.resolve(matches.map { scrollAreaFacts($0) }) {
            case let .unique(i): return matches[i]
            case let .ambiguous(labels):
                throw GhostHandsError.ambiguousMatch(name: named, candidates: labels)
            case .none: return nil
            }
        }

        // Auto-pick: prefer the scroll area enclosing the FOCUSED element (the one
        // the user is "in"); else the largest scroll area in the frontmost window
        // (so we never scroll an off-screen / background window's list).
        if let focusedArea = focusedScrollArea(in: target) {
            return focusedArea
        }
        let window = frontmostWindow(of: target) ?? target.element
        let areas = window.searchElements(
            byRole: "AXScrollArea", options: Self.boundedSearchOptions)
        return largestByArea(areas)
    }

    /// A bounded AX search options for scroll-area resolution. AXorcist's recursive
    /// search treats `maxDepth == 0` as NO limit, so a cyclic AX subtree (real apps
    /// expose them) overflows the stack and the process dies with SIGSEGV instead of
    /// returning an honest result. Bound the depth (the same guard Finder applies to
    /// every other resolve verb). No role/enabled filtering — a scroll area must not
    /// be dropped by those gates.
    @MainActor
    static var boundedSearchOptions: ElementSearchOptions {
        var o = ElementSearchOptions()
        o.maxDepth = Finder.maxSearchDepth
        return o
    }

    /// The app's main/focused window, else the first window. nil if it has none.
    @MainActor
    static func frontmostWindow(of target: Target) -> Element? {
        if let main = target.element.attribute(Attribute<AXUIElement>(
            AXAttributeNames.kAXMainWindowAttribute)) {
            return Element(main)
        }
        if let focused = target.element.attribute(Attribute<AXUIElement>(
            AXAttributeNames.kAXFocusedWindowAttribute)) {
            return Element(focused)
        }
        return target.element.windows()?.first
    }

    /// The scroll area ENCLOSING the app's focused UI element (walk up to the
    /// first AXScrollArea). nil when there is no focused element or it is not
    /// inside a scroll area.
    @MainActor
    static func focusedScrollArea(in target: Target) -> Element? {
        guard let focusedRef = target.element.attribute(Attribute<AXUIElement>(
            AXAttributeNames.kAXFocusedUIElementAttribute)) else { return nil }
        var current: Element? = Element(focusedRef)
        var hops = 0
        while let node = current, hops < 64 {
            if node.role() == "AXScrollArea" { return node }
            current = node.parent()
            hops += 1
        }
        return nil
    }

    /// The largest element by frame area (the primary content scroll area). A
    /// scroll area with no readable frame sorts last (area 0). nil for an empty set.
    @MainActor
    static func largestByArea(_ elements: [Element]) -> Element? {
        elements.max { a, b in
            let aa = a.frame().map { $0.width * $0.height } ?? 0
            let bb = b.frame().map { $0.width * $0.height } ?? 0
            return aa < bb
        }
    }

    /// A human label for the chosen scroll area — its title/identifier/role-desc,
    /// else a role-derived name. Never fabricated.
    @MainActor
    static func scrollAreaLabel(_ area: Element) -> String {
        if let t = area.title(), !t.isEmpty { return t }
        if let id = area.identifier(), !id.isEmpty { return id }
        if let rd = area.roleDescription(), !rd.isEmpty { return rd }
        return "scroll area"
    }

    // MARK: - scroll-bar witness

    /// The vertical or horizontal `AXScrollBar` child of a scroll area, if exposed.
    @MainActor
    static func scrollBar(of area: Element, vertical: Bool) -> Element? {
        let attr = vertical
            ? AXAttributeNames.kAXVerticalScrollBarAttribute
            : AXAttributeNames.kAXHorizontalScrollBarAttribute
        guard let ref = area.attribute(Attribute<AXUIElement>(attr)) else { return nil }
        return Element(ref)
    }

    /// Read a scroll bar's normalised position (`AXValue`, 0.0…1.0) as a Double,
    /// or nil when no numeric value is exposed (then we cannot observe a move).
    @MainActor
    static func scrollBarValue(_ bar: Element) -> Double? {
        scrollFraction(from: bar.value())
    }

    /// PURE-ish coercion of an AX value to a scroll fraction. A scroll bar's
    /// AXValue arrives as a boxed NSNumber; peel any boxed optional (the same
    /// trap `axString` handles) and read the double. Kept tolerant — a value the
    /// bar does not expose numerically yields nil (no observable), never a guess.
    static func scrollFraction(from value: Any?) -> Double? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first?.value else { return nil }
            return scrollFraction(from: inner)
        }
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: - actuation

    /// The fraction step for a one-page AX scroll-bar set. A page moves the
    /// visible window; on a normalised bar that is a portion of the full range.
    /// Used only for the AX-set route (the wheel route uses line deltas).
    static let scrollBarPageStep = 0.1

    /// Try the AX route: SET the scroll bar's `AXValue` to a clamped new fraction
    /// in the requested direction. Returns true only when the bar is settable AND
    /// the set was dispatched (a `true`); false ⇒ fall back to the wheel. The set
    /// being dispatched is NOT proof of a move — the after-witness decides that.
    @MainActor
    static func trySetScrollBar(_ bar: Element, before: Double,
                                direction: ScrollSpec.Direction, amount: Double) -> Bool {
        guard bar.isAttributeSettable(named: AXAttributeNames.kAXValueAttribute) else {
            return false
        }
        let delta = direction.sign * scrollBarPageStep * amount
        let next = min(1.0, max(0.0, before + delta))
        return bar.setValue(NSNumber(value: next),
                            forAttribute: AXAttributeNames.kAXValueAttribute)
    }

    /// Post a CGEvent `scrollWheel` aimed at the scroll area's center. Vertical
    /// uses wheel axis 1, horizontal axis 2 (with the horizontal value in the
    /// second field). The line delta is signed by direction and scaled by amount.
    /// `.invisible` posts to the app pid; `.visible` posts through the HID tap.
    @MainActor
    static func postScrollWheel(in area: Element, target: Target,
                                direction: ScrollSpec.Direction, amount: Double,
                                mode: PixelMode) {
        let lines = Int32((Double(scrollLinesPerPage) * amount).rounded()) * Int32(direction.sign)
        let src = CGEventSource(stateID: .hidSystemState)

        // Wheel deltas: a NEGATIVE wheel-1 scrolls content DOWN (toward higher
        // scroll-bar fraction), so flip the sign to match `direction.sign`
        // (positive = toward 1.0 = down/right).
        let wheel = -lines
        let event: CGEvent?
        if direction.isVertical {
            event = CGEvent(scrollWheelEvent2Source: src, units: .line,
                            wheelCount: 1, wheel1: wheel, wheel2: 0, wheel3: 0)
        } else {
            event = CGEvent(scrollWheelEvent2Source: src, units: .line,
                            wheelCount: 2, wheel1: 0, wheel2: wheel, wheel3: 0)
        }
        guard let event else { return }

        // Aim the wheel at the scroll area's center so the WindowServer hit-test
        // (the .visible path) routes it to this area. The .invisible per-pid post
        // ignores the point but we set it anyway for parity.
        if let f = area.frame() {
            event.location = CGPoint(x: f.midX, y: f.midY)
        }

        switch mode {
        case .invisible:
            event.postToPid(target.pid)
        case .visible:
            event.post(tap: .cghidEventTap)
        }
    }
}
