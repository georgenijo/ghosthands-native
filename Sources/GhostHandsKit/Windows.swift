import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation

/// The WINDOW-MANAGEMENT tier — `windows` (read) + `window move|resize|raise`.
///
/// Identity REUSES the repo's existing window mechanism, it does NOT reinvent it:
/// the per-window CGWindowID comes from `AXWindowResolver` (the same shim
/// `EffectProbe`, `Shot`, and `PixelClick` already pin windows with), and the
/// frame/title/minimized/main facts come from AXorcist's `Element` getters on the
/// AXWindow. The mutators use AXorcist's TYPED `setPosition`/`setSize` (which wrap
/// `AXValueCreate` correctly) and the raw `performAction(.raise)`.
///
/// Three honesty/invisibility realities, documented plainly rather than papered
/// over (they are this tier's HONEST LIMIT):
///
/// 1. INVISIBLE BY DEFAULT. `move`/`resize` set an AX attribute on the window —
///    no cursor, no focus steal, no app activation. `raise` is a STACKING change
///    (`AXRaise`) and nothing more: we deliberately use the raw raise, NOT
///    AXorcist's `focusWindow()`/`showWindow()` (which call `app.activate()` /
///    unminimize and STEAL focus). We never claim `raise` activated the app.
///
/// 2. VERIFY BY READ-BACK, never by the dispatch. `setPosition`/`setSize` return
///    an AXError, but AX frequently returns `.success` on a set the OS then
///    CLAMPS (minimum window size, off-screen guard) or a full-screen / modal
///    window IGNORES entirely. So the dispatch is never proof: we re-READ
///    `position()`/`size()` and run a pure verdict. Landed within tolerance →
///    VERIFIED; moved/resized but to a DIFFERENT value (OS constrained) →
///    DISPATCHED, reporting the ACTUAL landing (honest, not a fake verified, not
///    a refuse); AX-accepted-but-unchanged → DISPATCHED-UNVERIFIED.
///
/// 3. RAISE IS UNOBSERVABLE. AX exposes no reliable read-back of z-order, so
///    `raise` is ALWAYS dispatched-unverified — the stacking change is real (the
///    action did not throw) but we cannot prove it landed and we never pretend to.
///    A rejected `AXRaise` throws → REFUSE, mirroring the act tier.
///
/// AMBIGUITY refuses: more than one window and no `--window` selector → REFUSE
/// (mirroring click's ambiguous-match), rather than silently picking window[0].

// MARK: - Identity (per-window facts)

/// One window's observable facts, all read from the AX tree (or honestly nil when
/// AX does not expose them — a nil id/title is reported as unknown, never faked).
public struct WindowInfo: Sendable, Equatable {
    /// The CGWindowID via `AXWindowResolver` — nil when the private shim could not
    /// resolve one (reported as unknown, never fabricated).
    public let id: CGWindowID?
    public let title: String?
    /// GLOBAL top-left-origin frame (same space CGEvent uses — no flip).
    public let frame: CGRect
    /// Index into the active-display list whose bounds contain the frame center,
    /// or nil when the center is off every screen (Space-shifted / off-screen).
    public let screenIndex: Int?
    public let minimized: Bool
    public let isMain: Bool
    public let isFocused: Bool

    public init(id: CGWindowID?, title: String?, frame: CGRect, screenIndex: Int?,
                minimized: Bool, isMain: Bool, isFocused: Bool) {
        self.id = id
        self.title = title
        self.frame = frame
        self.screenIndex = screenIndex
        self.minimized = minimized
        self.isMain = isMain
        self.isFocused = isFocused
    }
}

/// PURE display-index mapping + selector matching over fabricated `WindowInfo`s.
/// Free of NSScreen / Target / AX so the whole identity decision is hermetically
/// testable — the live verbs pass in already-top-left screen rects.
public enum WindowList {
    /// Map a frame CENTER (GLOBAL top-left space) to the index of the first screen
    /// whose TOP-LEFT bounds contain it. Returns nil when the center is off every
    /// screen. `screens` MUST already be in top-left space (the caller converts at
    /// the one AX/AppKit boundary) so this stays a pure geometry function.
    ///
    /// Overlap / tie is deterministic: FIRST containing screen in list order wins.
    public static func screenIndex(forCenter center: CGPoint, in screens: [CGRect]) -> Int? {
        for (i, s) in screens.enumerated() where s.contains(center) {
            return i
        }
        return nil
    }

    /// The result of resolving a `--window <id|title>` selector against a window
    /// list (or the no-selector case). PURE so the refuse/ambiguous arms are
    /// testable on fabricated `WindowInfo`s — never a live app.
    public enum Selection: Sendable, Equatable {
        /// Exactly one window selected (its index into the supplied list).
        case one(Int)
        /// Zero windows in the app at all (caller maps to `.noWindows`).
        case empty
        /// More than one window and no selector, OR a selector matching >1 — REFUSE.
        case ambiguous(candidates: [String])
        /// A selector was given but matched no window — REFUSE.
        case notFound
    }

    /// Resolve which window to operate on. With NO selector: a single window is
    /// chosen, more than one REFUSES (ambiguous). With a selector: an id/title must
    /// match EXACTLY one window or it refuses (not-found / ambiguous). This is the
    /// pure mirror of click's ambiguity gate.
    public static func select(_ windows: [WindowInfo],
                              by selector: WindowSelector?) -> Selection {
        guard !windows.isEmpty else { return .empty }

        guard let selector else {
            // No selector: operate on the sole window, else refuse rather than
            // guess which of several to move.
            if windows.count == 1 { return .one(0) }
            return .ambiguous(candidates: windows.map { describe($0) })
        }

        let matches: [Int]
        switch selector {
        case let .id(wantedID):
            matches = windows.indices.filter { windows[$0].id == wantedID }
        case let .title(wantedTitle):
            let wanted = wantedTitle.lowercased()
            matches = windows.indices.filter {
                ($0 < windows.count) && (windows[$0].title?.lowercased() == wanted)
            }
        }

        switch matches.count {
        case 0: return .notFound
        case 1: return .one(matches[0])
        default: return .ambiguous(candidates: matches.map { describe(windows[$0]) })
        }
    }

    /// A short human label for a window, used in the ambiguity-refuse candidate
    /// list (id + quoted title, mirroring click's candidate wording).
    public static func describe(_ w: WindowInfo) -> String {
        let idPart = w.id.map { "id=\($0)" } ?? "id=?"
        let titlePart = (w.title?.isEmpty == false) ? w.title!.debugDescription : "(untitled)"
        return "\(idPart) \(titlePart)"
    }
}

/// How to pick a specific window when an app has more than one. `--window <id>`
/// (numeric → CGWindowID) or `--window <title>` (otherwise → exact title match).
public enum WindowSelector: Sendable, Equatable {
    case id(CGWindowID)
    case title(String)

    /// Parse a raw `--window` argument: an all-digit token is a CGWindowID, any
    /// other token is a title to match. (PURE — used by the CLI flag scan.)
    public static func parse(_ raw: String) -> WindowSelector {
        if let id = UInt32(raw) { return .id(id) }
        return .title(raw)
    }
}

// MARK: - Move / Resize verdict (PURE read-back honesty core)

/// The PURE move/resize honesty decision: given the TARGET, the BEFORE value and
/// the read-back AFTER value, decide VERIFIED (landed within tolerance) vs CLAMPED
/// (moved/resized but the OS constrained it to a different value — honest
/// dispatched, report the real landing) vs DISPATCHED (AX accepted but nothing
/// changed). A function of plain points/sizes so it is unit-testable with no live
/// window. The same shape serves move (CGPoint) and resize (CGSize).
public enum WindowFrameVerdict {
    /// Default read-back tolerance in points. Some apps quantize position/size to
    /// the backing scale or a layout grid, landing a pixel or two off the request;
    /// a small floor keeps that an honest VERIFIED rather than a false CLAMPED.
    public static let defaultTolerance: CGFloat = 2

    public enum Result: Sendable, Equatable {
        /// Read-back landed within tolerance of the target — honest VERIFIED.
        case verified
        /// Read-back MOVED/RESIZED from before, but not to the target (OS clamped /
        /// off-screen guard) — honest DISPATCHED, carrying the ACTUAL landing.
        case clamped(actualX: CGFloat, actualY: CGFloat)
        /// AX accepted but read-back equals before and != target — DISPATCHED,
        /// nothing observable changed (or the window ignored the set).
        case dispatched
    }

    /// Decide for a 2-component set (position OR size — both reduce to two scalars).
    /// `before`/`after` are the read-back pairs; `target` is the request.
    public static func decide(targetA: CGFloat, targetB: CGFloat,
                              beforeA: CGFloat, beforeB: CGFloat,
                              afterA: CGFloat, afterB: CGFloat,
                              tolerance: CGFloat = defaultTolerance) -> Result {
        let hitTarget = within(afterA, targetA, tolerance) && within(afterB, targetB, tolerance)
        if hitTarget { return .verified }

        // Did the value MOVE at all from where it started? If so the set landed but
        // the OS constrained it elsewhere → honest CLAMPED with the real landing.
        let moved = !within(afterA, beforeA, tolerance) || !within(afterB, beforeB, tolerance)
        if moved { return .clamped(actualX: afterA, actualY: afterB) }

        // AX accepted but the window is exactly where it started, and that isn't
        // the target → no observable change.
        return .dispatched
    }

    /// Convenience for a move (CGPoint) read-back.
    public static func decide(target: CGPoint, before: CGPoint, after: CGPoint,
                              tolerance: CGFloat = defaultTolerance) -> Result {
        decide(targetA: target.x, targetB: target.y,
               beforeA: before.x, beforeB: before.y,
               afterA: after.x, afterB: after.y, tolerance: tolerance)
    }

    /// Convenience for a resize (CGSize) read-back.
    public static func decide(target: CGSize, before: CGSize, after: CGSize,
                              tolerance: CGFloat = defaultTolerance) -> Result {
        decide(targetA: target.width, targetB: target.height,
               beforeA: before.width, beforeB: before.height,
               afterA: after.width, afterB: after.height, tolerance: tolerance)
    }

    @inline(__always)
    private static func within(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat) -> Bool {
        abs(a - b) <= tol
    }
}

// MARK: - Outcomes (honest — verified is never inferred from the dispatch)

public struct WindowsResult: Sendable, Equatable {
    public let app: String
    public let windows: [WindowInfo]
    public var count: Int { windows.count }

    public init(app: String, windows: [WindowInfo]) {
        self.app = app
        self.windows = windows
    }
}

/// A move/resize outcome. `axAccepted` is the dispatch (the typed set's AXError
/// was `.success`); `verified` is the READ-BACK truth, never the dispatch.
/// `clamped` flags an honest "moved/resized but the OS constrained it" with the
/// actual landed frame; `verb` distinguishes the report wording.
public struct WindowMutateOutcome: Sendable, Equatable {
    public let app: String
    public let verb: String          // "move" | "resize"
    public let windowTitle: String?
    public let windowID: CGWindowID?
    public let axAccepted: Bool
    public let verified: Bool
    /// True when the set landed but the OS constrained it to a different value than
    /// requested — honest dispatched, the actual frame is in `frameAfter`.
    public let clamped: Bool
    public let frameBefore: CGRect
    public let frameAfter: CGRect

    public init(app: String, verb: String, windowTitle: String?, windowID: CGWindowID?,
                axAccepted: Bool, verified: Bool, clamped: Bool,
                frameBefore: CGRect, frameAfter: CGRect) {
        self.app = app
        self.verb = verb
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.axAccepted = axAccepted
        self.verified = verified
        self.clamped = clamped
        self.frameBefore = frameBefore
        self.frameAfter = frameAfter
    }
}

/// A raise outcome — ALWAYS dispatched-unverified (AX has no z-order read-back).
/// `axAccepted` true means `AXRaise` did not throw; `verified` is always false
/// (the stacking change is unobservable). A reject throws before this is built.
public struct WindowRaiseOutcome: Sendable, Equatable {
    public let app: String
    public let windowTitle: String?
    public let windowID: CGWindowID?
    public let axAccepted: Bool
    public let verified: Bool       // always false — z-order is unobservable

    public init(app: String, windowTitle: String?, windowID: CGWindowID?,
                axAccepted: Bool, verified: Bool) {
        self.app = app
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.axAccepted = axAccepted
        self.verified = verified
    }
}

// MARK: - Live verbs

extension GhostHands {

    /// `windows <app>` — pure read of every AXWindow's identity + facts. No focus
    /// steal, no AXRaise, no mutation. A nil id/frame is reported as unknown, never
    /// fabricated. Always an honest verified OBSERVATION (it is just reporting AX
    /// facts).
    @MainActor
    public static func windows(appSpec: String) throws -> WindowsResult {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)
        let infos = try enumerate(target: target).map { $0.info }
        return WindowsResult(app: target.name, windows: infos)
    }

    /// `window move <x> <y> <app> [--window <id|title>]` — set the window's GLOBAL
    /// top-left position via the typed `setPosition`, then RE-READ `position()` and
    /// run the pure verdict. INVISIBLE (no cursor/focus). Honest about VERIFIED vs
    /// OS-CLAMPED vs DISPATCHED — never a fake success.
    @MainActor
    public static func windowMove(x: Double, y: Double, appSpec: String,
                                  selector: WindowSelector? = nil,
                                  settle: TimeInterval = 0.1) throws -> WindowMutateOutcome {
        let (target, axWindow, info) = try selectWindow(appSpec: appSpec, selector: selector)

        guard let before = axWindow.frame() else {
            throw GhostHandsError.captureFailed(
                reason: "could not read the window's position before move")
        }
        let targetPoint = CGPoint(x: x, y: y)
        let err = axWindow.setPosition(targetPoint)
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        // Read back — the ONLY truth. AX often returns .success on a clamped/ignored
        // set, so the dispatch is recorded but never used as proof.
        let after = axWindow.position() ?? before.origin
        let axAccepted = (err == .success)

        let verdict = WindowFrameVerdict.decide(target: targetPoint,
                                                before: before.origin, after: after)
        let (verified, clamped): (Bool, Bool)
        switch verdict {
        case .verified: (verified, clamped) = (true, false)
        case .clamped: (verified, clamped) = (false, true)
        case .dispatched: (verified, clamped) = (false, false)
        }
        return WindowMutateOutcome(
            app: target.name, verb: "move", windowTitle: info.title, windowID: info.id,
            axAccepted: axAccepted, verified: verified, clamped: clamped,
            frameBefore: before,
            frameAfter: CGRect(origin: after, size: before.size))
    }

    /// `window resize <w> <h> <app> [--window <id|title>]` — set the window size via
    /// the typed `setSize`, then RE-READ `size()` and run the same pure verdict.
    /// Honest about VERIFIED vs OS-CLAMPED (min-size / full-screen) vs DISPATCHED.
    @MainActor
    public static func windowResize(w: Double, h: Double, appSpec: String,
                                    selector: WindowSelector? = nil,
                                    settle: TimeInterval = 0.1) throws -> WindowMutateOutcome {
        let (target, axWindow, info) = try selectWindow(appSpec: appSpec, selector: selector)

        guard let before = axWindow.frame() else {
            throw GhostHandsError.captureFailed(
                reason: "could not read the window's size before resize")
        }
        let targetSize = CGSize(width: w, height: h)
        let err = axWindow.setSize(targetSize)
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        let after = axWindow.size() ?? before.size
        let axAccepted = (err == .success)

        let verdict = WindowFrameVerdict.decide(target: targetSize,
                                                before: before.size, after: after)
        let (verified, clamped): (Bool, Bool)
        switch verdict {
        case .verified: (verified, clamped) = (true, false)
        case .clamped: (verified, clamped) = (false, true)
        case .dispatched: (verified, clamped) = (false, false)
        }
        return WindowMutateOutcome(
            app: target.name, verb: "resize", windowTitle: info.title, windowID: info.id,
            axAccepted: axAccepted, verified: verified, clamped: clamped,
            frameBefore: before,
            frameAfter: CGRect(origin: before.origin, size: after))
    }

    /// `window raise <app> [--window <id|title>]` — `AXRaise` the window (a STACKING
    /// change only). We use the RAW raise, NOT focusWindow()/showWindow() (which
    /// steal focus / activate). z-order has no AX read-back → ALWAYS dispatched-
    /// unverified; a rejected raise throws → REFUSE. Never activates the app.
    @MainActor
    public static func windowRaise(appSpec: String,
                                   selector: WindowSelector? = nil) throws -> WindowRaiseOutcome {
        let (target, axWindow, info) = try selectWindow(appSpec: appSpec, selector: selector)
        do {
            _ = try axWindow.performAction(.raise)
        } catch {
            // AX rejected the raise — honest REFUSE, no fabricated stacking change.
            throw GhostHandsError.actionRejected(name: info.title ?? target.name, action: "AXRaise")
        }
        return WindowRaiseOutcome(app: target.name, windowTitle: info.title,
                                  windowID: info.id, axAccepted: true, verified: false)
    }

    // MARK: - shared window resolution

    /// A live AXWindow paired with its already-read identity facts.
    struct ResolvedWindow {
        let element: Element
        let info: WindowInfo
    }

    /// Enumerate every AXWindow of `target` as (live element, identity facts). The
    /// CGWindowID reuses `AXWindowResolver`; the facts reuse AXorcist's getters; the
    /// display index maps the frame center against TOP-LEFT screen bounds (NOT
    /// AXorcist's mixed-space windowScreen()). The app's focused window is flagged by
    /// matching its windowID.
    ///
    /// THROWS `.windowListUnreadable` when `windows()` returns nil — an AX
    /// enumeration FAILURE, distinct from an app that genuinely has zero windows
    /// (which returns an empty array). We never collapse the two: a read failure
    /// must not masquerade as "no windows".
    @MainActor
    static func enumerate(target: Target) throws -> [ResolvedWindow] {
        guard let axWindows = target.element.windows() else {
            throw GhostHandsError.windowListUnreadable(app: target.name)
        }
        let resolver = AXWindowResolver()
        let focusedID = target.element.focusedWindow().flatMap { resolver.windowID(from: $0) }
        let screens = topLeftScreenRects()

        return axWindows.map { win in
            let id = resolver.windowID(from: win)
            let frame = win.frame() ?? .zero
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let screenIndex = WindowList.screenIndex(forCenter: center, in: screens)
            let focused: Bool = {
                guard let id, let focusedID else { return false }
                return id == focusedID
            }()
            let info = WindowInfo(
                id: id,
                title: win.title(),
                frame: frame,
                screenIndex: screenIndex,
                minimized: win.isMinimized() ?? false,
                isMain: win.isMain() ?? false,
                isFocused: focused)
            return ResolvedWindow(element: win, info: info)
        }
    }

    /// Resolve the single window to mutate, honoring the selector + ambiguity refuse
    /// (mirrors click's ambiguous-match). Returns the live element + its facts.
    @MainActor
    static func selectWindow(appSpec: String, selector: WindowSelector?)
        throws -> (target: Target, window: Element, info: WindowInfo) {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)
        let resolved = try enumerate(target: target)
        let infos = resolved.map { $0.info }

        switch WindowList.select(infos, by: selector) {
        case let .one(i):
            return (target, resolved[i].element, resolved[i].info)
        case .empty:
            throw GhostHandsError.noWindows(app: target.name)
        case let .ambiguous(candidates):
            throw GhostHandsError.windowAmbiguous(app: target.name, candidates: candidates)
        case .notFound:
            throw GhostHandsError.windowNotFound(app: target.name,
                                                 selector: selectorDescription(selector))
        }
    }

    /// Build the active-display bounds in TOP-LEFT global space (the same space the
    /// AX frame center lives in) so the display index is correct on multi-monitor
    /// rigs of differing heights. We use `CGDisplayBounds` (already top-left) over
    /// NSScreen.frame (Cocoa bottom-left) to avoid the mixed-space bug AXorcist's
    /// own windowScreen() has. This is the ONE AX/AppKit boundary; the geometry
    /// itself is the pure `WindowList.screenIndex`.
    @MainActor
    static func topLeftScreenRects() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    static func selectorDescription(_ selector: WindowSelector?) -> String {
        switch selector {
        case let .id(id): return "id=\(id)"
        case let .title(t): return t.debugDescription
        case .none: return "(none)"
        }
    }
}
