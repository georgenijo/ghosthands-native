import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation

/// The outcome of a `right-click` — open an element's CONTEXT MENU, honestly.
///
/// Mirrors the click/act honesty split: `dispatched` is only that the action was
/// SENT (AXShowMenu performed, or a real right-click posted); `verified` is the
/// stronger, independently-observable claim that a context `AXMenu` actually
/// APPEARED. A context menu is the one self-observable a right-click HAS — the
/// menu pops into the app's AX tree — so when we can see a new `AXMenu` we
/// promote to VERIFIED, and when we cannot (the action landed but no menu was
/// observed, or the menu was suppressed/in a process we can't read) we report
/// DISPATCHED-UNVERIFIED, never a faked success.
public struct RightClickOutcome: Sendable, Equatable {
    public let app: String
    public let name: String
    public let role: String
    /// The route actually taken — `.axShowMenu` (the element advertised the AX
    /// action) or `.pixel` (no AXShowMenu → a real CGEvent right-click). Surfaced
    /// so the report can LABEL the pixel route's weaker invisibility guarantees.
    public let route: RightClickRoute
    /// The delivery mode for the PIXEL route (ignored for the AX route, which is
    /// always invisible). `.visible` is LABELLED in the report.
    public let mode: PixelMode
    /// The action was SENT (AXShowMenu performed without throwing, or the mouse
    /// events posted). Never proof of effect on its own — see `verified`.
    public let dispatched: Bool
    /// A context `AXMenu` was OBSERVED to appear after the action — the only
    /// honest VERIFIED for a right-click.
    public let verified: Bool
    /// Human evidence string for the VERIFIED case (e.g. "context menu appeared
    /// (1 → 2 menus)"), nil when dispatched-unverified.
    public let evidence: String?

    public init(app: String, name: String, role: String, route: RightClickRoute,
                mode: PixelMode = .invisible, dispatched: Bool, verified: Bool,
                evidence: String?) {
        self.app = app
        self.name = name
        self.role = role
        self.route = route
        self.mode = mode
        self.dispatched = dispatched
        self.verified = verified
        self.evidence = evidence
    }
}

/// Which route a right-click took. AX-first (the invisible, advertised path);
/// pixel fallback only when the control does not advertise `AXShowMenu`.
public enum RightClickRoute: Sendable, Equatable {
    /// The element advertised `AXShowMenu` — performed it (invisible, no cursor).
    case axShowMenu
    /// No `AXShowMenu` advertised — posted a real CGEvent right-click at center.
    case pixel
}

/// The PURE verdict for a right-click — fabricated facts in, honest verdict out.
///
/// A right-click's ONLY self-observable is that a context `AXMenu` appears in the
/// app's AX tree. We count menus before vs after the action and decide:
/// - a NEW menu appeared (after > before) → VERIFIED, regardless of route,
/// - the action was sent but NO new menu was observed → DISPATCHED-UNVERIFIED
///   (honest under-claim — the AX route's `AXShowMenu` may have been accepted
///   with no menu, or the pixel poke landed on a surface we can't witness),
/// - the action was NOT even sent (an AX reject upstream becomes a REFUSE; this
///   decider never sees that case — a non-dispatched input is reported `.refuse`
///   only as a defensive guard so the enum is total).
///
/// This is the audited honesty boundary, kept AX-free so the menu-appeared /
/// accepted-but-no-menu / pixel-route arms are hermetically unit-testable with
/// no live app. The live verb feeds it a real before/after `AXMenu` count.
public enum MenuVerdict {
    public enum Result: Sendable, Equatable {
        /// A context menu was observed to appear — quote the before → after count.
        case verified(evidence: String)
        /// The action was sent but no new menu was observed — honest under-claim.
        case dispatched
        /// The action was never even sent (defensive; the verb refuses upstream).
        case refuse
    }

    /// Decide from honest structural facts.
    ///
    /// `dispatched` is whether the action was actually SENT (AXShowMenu performed,
    /// or the mouse events posted). `menusBefore`/`menusAfter` are the counts of
    /// context `AXMenu` elements present in the app's AX tree BEFORE and AFTER the
    /// action — the witness. A genuinely NEW menu (after > before) is the proof;
    /// anything else is an honest dispatch (never a fabricated success). The
    /// verdict is IDENTICAL for the AX and pixel routes — honesty does not depend
    /// on HOW we opened the menu, only on whether a menu was OBSERVED.
    public static func decide(dispatched: Bool, menusBefore: Int,
                              menusAfter: Int) -> Result {
        guard dispatched else { return .refuse }
        if menusAfter > menusBefore {
            let delta = menusAfter - menusBefore
            let noun = delta == 1 ? "menu" : "menus"
            return .verified(
                evidence: "context menu appeared (\(menusBefore) → \(menusAfter) \(noun))")
        }
        return .dispatched
    }
}

extension GhostHands {
    /// Roles that may own a context menu — the `right-click` candidate gate. A
    /// right-click is meaningful on far more than a pushable button: rows, cells,
    /// list/outline items, text, links, images and groups all routinely carry a
    /// context menu. We therefore accept the click/openable control roles PLUS the
    /// value/content roles a context menu commonly hangs off, so `right-click` can
    /// target a Finder row or a web link, not just an AXButton. A control that
    /// advertises AXShowMenu is accepted regardless of role. Still excludes the
    /// menu roles themselves (handled by `Finder.excludedRoles`).
    nonisolated static let rightClickableContentRoles: Set<String> = [
        "AXStaticText", "AXImage", "AXGroup", "AXTextField", "AXTextArea",
    ]
    nonisolated static func isRightClickable(_ facts: ElementFacts) -> Bool {
        Finder.isOpenable(facts)
            || facts.supports("AXShowMenu")
            || (facts.role.map { rightClickableContentRoles.contains($0) } ?? false)
    }

    /// `right-click "<name>" <app> [--visible]` — open the named element's CONTEXT
    /// MENU, honestly, in honesty order:
    ///
    /// 1. RESOLVE the named element (same refuse-on-not-found / refuse-on-ambiguous
    ///    rules as `click`).
    /// 2. Prefer the AX route: if the element advertises `AXShowMenu`, perform it
    ///    (invisible, cursor-less). WITNESS: count context `AXMenu`s in the app
    ///    tree before/after — a new menu → VERIFIED, accepted-but-no-menu →
    ///    DISPATCHED-UNVERIFIED.
    /// 3. If `AXShowMenu` is NOT advertised: post a REAL right-click (CGEvent
    ///    rightMouseDown + rightMouseUp) at the element CENTER — invisible via
    ///    postToPid by default, `.cghidEventTap` when `--visible`. A pixel
    ///    right-click has no self-signal, so it is dispatched-unverified UNLESS we
    ///    still witness a new `AXMenu`, in which case we promote to VERIFIED.
    /// 4. not-found / ambiguous → REFUSE (reuse `.elementNotFound` / `.ambiguousMatch`).
    ///
    /// Nothing here hardcodes success: a thrown `AXShowMenu` or an
    /// un-bounds-checkable element REFUSES; a sent action with no observed menu is
    /// honestly dispatched-unverified.
    @MainActor
    public static func rightClick(name: String, appSpec: String,
                                  mode: PixelMode = .invisible,
                                  locator: LocatorSpec = .none,
                                  settle: TimeInterval = 0.15) throws -> RightClickOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        let element: Element
        let facts: ElementFacts
        switch Finder.resolve(named: name, under: target.element, accept: isRightClickable,
                              locator: locator) {
        case let .element(found, foundFacts):
            element = found
            facts = foundFacts
        case let .ambiguous(candidates):
            throw GhostHandsError.ambiguousMatch(name: name, candidates: candidates)
        case let .indexOutOfRange(requested, count):
            throw GhostHandsError.locatorIndexOutOfRange(name: name, requested: requested, count: count)
        case .none:
            throw GhostHandsError.elementNotFound(name: name, app: target.name)
        }

        let role = facts.role ?? "AXUnknown"

        // WITNESS BEFORE: count context AXMenu elements across the app's AX tree.
        // A context menu pops in as a NEW AXMenu, so a count that GROWS across the
        // action is the proof. Counted off a FRESH app root so we read the world,
        // never a stale handle. (See MenuProbe for the scoping rationale.)
        let probe = MenuProbe(pid: target.pid)
        let menusBefore = probe.menuCount()

        Highlight.flashIfEnabled(element)
        let route: RightClickRoute
        if facts.supports("AXShowMenu") {
            // PREFERRED AX ROUTE — invisible, cursor-less. A throw here is a REFUSE
            // (the control advertised AXShowMenu but rejected the perform), mirroring
            // `act`'s honest .actionRejected rather than a fabricated success.
            // Note: on a popup/menu-button the menu AXShowMenu opens is that
            // control's DROPDOWN (still a real `AXMenu`); the witness/report wording
            // "context menu" reads it as a menu genuinely appearing, which is honest
            // even though a dropdown is not strictly a right-click context menu.
            route = .axShowMenu
            do {
                _ = try element.performAction("AXShowMenu")
            } catch {
                throw GhostHandsError.actionRejected(name: name, action: "AXShowMenu")
            }
        } else {
            // PIXEL FALLBACK — no AXShowMenu advertised. Post a real right-click at
            // the element CENTER. Requires a readable frame to aim at; an element
            // with no AX geometry cannot be honestly right-clicked → REFUSE rather
            // than poke a guessed point.
            route = .pixel
            guard let frame = facts.frame, frame.width > 0, frame.height > 0 else {
                throw GhostHandsError.noElementFrame(name: name)
            }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            postRightClick(at: center, pid: target.pid, mode: mode)
        }

        // Let the menu open, then WITNESS AFTER off a fresh app root.
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        let menusAfter = probe.menuCount()

        let verdict = MenuVerdict.decide(dispatched: true, menusBefore: menusBefore,
                                         menusAfter: menusAfter)
        switch verdict {
        case let .verified(evidence):
            return RightClickOutcome(app: target.name, name: name, role: role,
                                     route: route, mode: mode, dispatched: true,
                                     verified: true, evidence: evidence)
        case .dispatched, .refuse:
            // `.refuse` cannot occur here (we always dispatch before deciding); it
            // is collapsed into the honest dispatched-unverified report defensively.
            return RightClickOutcome(app: target.name, name: name, role: role,
                                     route: route, mode: mode, dispatched: true,
                                     verified: false, evidence: nil)
        }
    }

    /// Post a REAL right-click (rightMouseDown + rightMouseUp) at a GLOBAL screen
    /// point. Mirrors `postMouseSequence`'s honesty/invisibility contract:
    ///
    /// - `.invisible` (DEFAULT): deliver both events straight to the target `pid`
    ///   via `CGEventPostToPid` — cursor-less, no warp, no HID tap, background
    ///   best-effort. The on-screen pointer never moves. `postToPid` is
    ///   coordinate-only (no OS hit-test), so a non-key / non-AppKit surface may
    ///   ignore it — honestly surfaced as dispatched-unverified by the menu witness.
    /// - `.visible` (LABELLED exception): warp the real cursor and post through
    ///   `.cghidEventTap` so the WindowServer hit-tests the window under the point.
    ///   Saves/restores the cursor. NOT invisible — may move the pointer / steal
    ///   focus.
    @MainActor
    static func postRightClick(at point: CGPoint, pid: pid_t, mode: PixelMode) {
        let src = CGEventSource(stateID: .hidSystemState)
        switch mode {
        case .invisible:
            if let down = CGEvent(mouseEventSource: src, mouseType: .rightMouseDown,
                                  mouseCursorPosition: point, mouseButton: .right) {
                down.postToPid(pid)
            }
            if let up = CGEvent(mouseEventSource: src, mouseType: .rightMouseUp,
                                mouseCursorPosition: point, mouseButton: .right) {
                up.postToPid(pid)
            }
        case .visible:
            let savedPos = CGEvent(source: nil)?.location ?? point
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(1)
            usleep(8000)   // the standard warp-then-post settle (mirrors PixelClick).
            if let down = CGEvent(mouseEventSource: src, mouseType: .rightMouseDown,
                                  mouseCursorPosition: point, mouseButton: .right) {
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: src, mouseType: .rightMouseUp,
                                mouseCursorPosition: point, mouseButton: .right) {
                up.post(tap: .cghidEventTap)
            }
            CGWarpMouseCursorPosition(savedPos)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}

/// Counts the context `AXMenu` elements present in an app's AX tree — the
/// right-click witness. A context menu opened by AXShowMenu / a right-click pops
/// in as a NEW `AXMenu`, so a count that GROWS across the action is independent
/// proof the menu appeared. Walking from a FRESH application root (never a stale
/// handle) each time, with the SAME bounded walk both reads, keeps the count
/// honest and comparable.
///
/// We count `AXMenu` ANYWHERE in the app tree (not scoped to the element's
/// window) on purpose: a context menu is a top-level borderless panel parented
/// off the application — not inside the originating window's subtree — so a
/// window-scoped walk would MISS it and fabricate a false dispatched-unverified.
/// The app-wide count cannot over-claim either: the verdict only fires on an
/// INCREASE, and the two reads are ADJACENT (same bounded walk, moments apart).
/// Any `AXMenu` already open before the action — including an open menu-bar menu —
/// appears in BOTH reads and so produces no delta; the only thing that can grow
/// the count between two adjacent reads is the context menu we just asked for.
/// (Note this raw walk counts every `AXMenu` directly — it does NOT apply
/// `Finder.excludedRoles`, which only filters element SEARCHES during resolution;
/// the delta-only, adjacent-reads argument is the actual guarantee here.)
@MainActor
struct MenuProbe {
    let pid: pid_t
    static let maxDepth = 80

    /// The number of `AXMenu` elements currently in the app's AX tree.
    func menuCount() -> Int {
        let root = Element(AXUIElementCreateApplication(pid))
        var visited = Set<Element>()
        return count(root, depth: 0, visited: &visited)
    }

    private func count(_ element: Element, depth: Int,
                       visited: inout Set<Element>) -> Int {
        guard depth < Self.maxDepth, !visited.contains(element) else { return 0 }
        visited.insert(element)
        var n = (element.role() == "AXMenu") ? 1 : 0
        // Search-merged children (strict:false) so a menu attached via an
        // alternate attribute (some apps parent the context menu off the app via
        // AXChildren, others expose it only through the search merge) is still
        // counted — the witness must not miss a menu the app opened.
        let kids = element.children(strict: false) ?? []
        for child in kids {
            n += count(child, depth: depth + 1, visited: &visited)
        }
        return n
    }
}
