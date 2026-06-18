import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The PIXEL ACTUATION tier — `click-at` and `drag`.
///
/// This is the HANDS gap: a click/drag at a caller-supplied GLOBAL screen point
/// when there is NO AX element to target. Coordinates come from the caller; this
/// is NOT a vision/model feature — there is no model, no MLX, no network here.
///
/// Two honesty/invisibility realities make this tier weaker than the AX verbs,
/// and we document them plainly rather than papering over them:
///
/// 1. INVISIBILITY (best-effort): we synthesize the mouse events with `CGEvent`
///    and deliver them straight to the TARGET app's pid via `CGEventPostToPid`,
///    bypassing the system HID tap and the window-server hit-test. That is the
///    least-visible path — it does NOT drive the on-screen pointer — and it can
///    reach a BACKGROUND window. But `postToPid` is coordinate-only (no real
///    hit-test): standard AppKit apps map the point to a view, while some
///    non-AppKit / game / custom surfaces may ignore or mis-route it, and the app
///    may itself react by moving focus or showing a cursor. Pixel mode is more
///    visible / less guaranteed than the AX verbs.
///
/// 2. HONESTY (the hard part): `postToPid` returns no signal, so a returning post
///    is NEVER proof of effect. We VERIFY by SCREENSHOT-DIFF — capture the target
///    window before and after (reusing the `shot` ScreenCaptureKit path) and diff
///    the pixels in a neighborhood around the click point. Pixels changed ⇒
///    VERIFIED; no change ⇒ DISPATCHED-UNVERIFIED (clicked, no observable effect
///    — never success). If Screen Recording is not granted we still dispatch the
///    click but report DISPATCHED-UNVERIFIED honestly (we acted, cannot prove).
///    We REFUSE (throw) if the app can't be resolved or the point is outside the
///    target window's bounds (don't poke a random location).
///
///    Read VERIFIED precisely: it means "the pixels near the point CHANGED
///    between the two frames," not strict causation. We narrow the diff to the
///    click neighborhood and exclude the system cursor so unrelated/pointer
///    repaints don't count, but a region that repaints on its OWN (a spinner,
///    blinking caret, video, live clock, progress bar) under the point can clear
///    the threshold regardless of the click — so on a self-animating surface a
///    VERIFIED is "changed near the point," not proof THIS click caused it.
///    The verdict is also SETTLE-WINDOW dependent: a slow app that repaints after
///    the fixed settle reads as DISPATCHED-UNVERIFIED. That direction only ever
///    UNDER-claims (a late paint never fabricates a VERIFIED), so it is honest,
///    but the same poke can read verified on a fast app and unverified on a slow
///    one purely on paint latency.
/// How a pixel poke is delivered. This is the INVISIBILITY axis of the contract.
///
/// - `.invisible` (DEFAULT): synthesize the events and deliver them straight to
///   the target app's pid via `CGEventPostToPid` — cursor-less, no warp, no HID
///   tap, background-capable best-effort. The on-screen pointer never moves. But
///   `postToPid` is coordinate-only (no real OS hit-test): standard AppKit apps
///   map the point to a view, while some non-AppKit / game / custom surfaces (and
///   some plain AppKit windows that are not key) IGNORE it — the dispatch lands
///   but actuates nothing, honestly reported as DISPATCHED-UNVERIFIED.
///
/// - `.visible` (LABELLED exception): warp the REAL cursor to the point and post
///   the events through the HID tap (`.cghidEventTap`), so the WindowServer runs
///   its true hit-test and actuates the window under the point — the path that
///   lands on a backgrounded AppKit window `postToPid` could not reach. The
///   trade-off, stated plainly: it MOVES / flickers the visible cursor, and
///   macOS routes the HID mouse to whatever window is FRONTMOST under the point
///   (an OS wall) — so `.visible` is NOT invisible, may FOREGROUND / steal focus,
///   and cannot actuate a truly background window without raising it.
///
///   One honesty caveat specific to `.visible`: the verify-by-diff measures the
///   TARGET app's AX-frontmost window (the one we bounds-checked and captured),
///   but the HID click lands on whatever window is SCREEN-frontmost under the
///   point. When windows OVERLAP these can be different windows, so the verdict
///   reflects the TARGET window's repaint, NOT proof the HID landed on it. That
///   mismatch only ever UNDER-claims (a foreign-window click reads as
///   DISPATCHED-UNVERIFIED) — it can never fabricate a false VERIFIED.
public enum PixelMode: Sendable, Equatable {
    /// CGEventPostToPid, cursor-less best-effort (default).
    case invisible
    /// CGWarpMouseCursorPosition + .cghidEventTap — moves the real cursor.
    case visible
}

public struct PixelOutcome: Sendable, Equatable {
    public let app: String
    /// The verb that ran ("click-at" / "drag"), for the report string.
    public let verb: String
    /// The end point that was diffed (global screen point), for the report.
    public let x: Double
    public let y: Double
    public let dispatched: Bool
    public let verified: Bool
    /// True when we were ABLE to observe (Screen Recording granted + both
    /// captures succeeded). When false, `verified` is false and the report says
    /// we could not look — distinct from "looked and saw nothing".
    public let observable: Bool
    /// The measured changed-fraction of the diffed neighborhood (0 when not
    /// observable). Quoted in the VERIFIED evidence string.
    public let changedFraction: Double
    /// The delivery mode used. `.visible` is surfaced in the report so a moved /
    /// flickered cursor + possible focus steal is LABELLED, never silent.
    public let mode: PixelMode

    public init(app: String, verb: String, x: Double, y: Double, dispatched: Bool,
                verified: Bool, observable: Bool, changedFraction: Double,
                mode: PixelMode = .invisible) {
        self.app = app
        self.verb = verb
        self.x = x
        self.y = y
        self.dispatched = dispatched
        self.verified = verified
        self.observable = observable
        self.changedFraction = changedFraction
        self.mode = mode
    }
}

extension GhostHands {
    /// The diff neighborhood half-size (in points) around the click point. A
    /// click repaints a button-sized region; we focus there so a distant clock
    /// tick or unrelated repaint cannot become false evidence.
    static let pixelDiffRadius = 24

    /// `click-at <x> <y> <app>` — left click at a GLOBAL screen point, targeting
    /// `app`'s frontmost window. See the type doc for the honesty/invisibility
    /// contract. Returns an outcome that is honest about VERIFIED vs DISPATCHED.
    @MainActor
    public static func clickAt(x: Double, y: Double, appSpec: String,
                               mode: PixelMode = .invisible,
                               settle: TimeInterval = 0.12) async throws -> PixelOutcome {
        try await pixelPoke(verb: "click-at", start: CGPoint(x: x, y: y),
                            end: CGPoint(x: x, y: y), appSpec: appSpec,
                            mode: mode, settle: settle)
    }

    /// `drag <x1> <y1> <x2> <y2> <app>` — press at `(x1,y1)`, move (interpolated
    /// `.leftMouseDragged` so a drag target sees a continuous drag, not a hover),
    /// release at `(x2,y2)`. Both endpoints must lie inside the target window.
    /// Verified by a screenshot diff of the neighborhood around the END point.
    @MainActor
    public static func drag(x1: Double, y1: Double, x2: Double, y2: Double,
                            appSpec: String,
                            mode: PixelMode = .invisible,
                            settle: TimeInterval = 0.12) async throws -> PixelOutcome {
        try await pixelPoke(verb: "drag", start: CGPoint(x: x1, y: y1),
                            end: CGPoint(x: x2, y: y2), appSpec: appSpec,
                            mode: mode, settle: settle)
    }

    /// The shared dispatch+verify core for both pixel verbs.
    @MainActor
    static func pixelPoke(verb: String, start: CGPoint, end: CGPoint,
                          appSpec: String, mode: PixelMode = .invisible,
                          settle: TimeInterval) async throws -> PixelOutcome {
        // Bootstrap the WindowServer connection exactly once (same reason as
        // `shot`): CGS / ScreenCaptureKit / CGPreflight calls abort uncatchably
        // without it. Stays a background accessory — no focus steal, no cursor.
        _ = NSApplication.shared

        // Synthetic event posting requires the Accessibility grant; without it
        // postToPid silently no-ops, so gate up front like the AX verbs.
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }

        let target = try Target.resolve(appSpec)

        // Resolve the frontmost window so we can (a) bounds-check the point and
        // (b) capture it for the before/after diff.
        let windows = target.element.windows() ?? []
        guard let axWindow = windows.first else {
            throw GhostHandsError.noWindows(app: target.name)
        }
        // AXorcist's `frame()` returns the window's GLOBAL top-left-origin rect —
        // the same space CGEvent's mouseCursorPosition uses, so no flip is needed.
        guard let frame = axWindow.frame(), frame.width > 0, frame.height > 0 else {
            throw GhostHandsError.captureFailed(
                reason: "could not read the target window's frame for bounds-checking")
        }

        // REFUSE out-of-bounds: don't poke a random screen location. Both drag
        // endpoints must be on the window.
        if PixelBounds.decide(point: start, windowFrame: frame) == .outside {
            throw GhostHandsError.pointOutsideWindow(
                point: "(\(Int(start.x)),\(Int(start.y)))",
                window: rectString(frame), app: target.name)
        }
        if verb == "drag",
           PixelBounds.decide(point: end, windowFrame: frame) == .outside {
            throw GhostHandsError.pointOutsideWindow(
                point: "(\(Int(end.x)),\(Int(end.y)))",
                window: rectString(frame), app: target.name)
        }

        // Try to capture BEFORE — but only if we can observe at all. A missing
        // Screen Recording grant does NOT block the dispatch; it just means we
        // verify-by-diff is impossible, so we will report DISPATCHED-UNVERIFIED.
        let resolver = AXWindowResolver()
        let windowID = resolver.windowID(from: axWindow)
        let before = await PixelCapture.captureWindow(cgWindowID: windowID)

        // DISPATCH the events. `.invisible` posts straight to the target pid
        // (cursor-less); `.visible` warps the real cursor and posts via the HID
        // tap so the WindowServer hit-tests and actuates the front window.
        postMouseSequence(start: start, end: end, pid: target.pid,
                          isDrag: verb == "drag", mode: mode)

        // Let the app paint, then capture AFTER off the SAME window id.
        if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
        let after = await PixelCapture.captureWindow(cgWindowID: windowID)

        // Map the END point (global, top-left) into window-local pixel space for
        // the diff neighborhood. captureWindow returns 1x (point-valued config),
        // so window-local POINTS == buffer PIXELS — a clean apples-to-apples diff.
        let observable: Bool
        let fraction: Double
        if let b = before, let a = after, b.isValid, a.isValid {
            let localX = Int((end.x - frame.minX).rounded())
            let localY = Int((end.y - frame.minY).rounded())
            let region = PixelRegion.centered(cx: localX, cy: localY, radius: pixelDiffRadius)
            fraction = PixelDiff.changedFraction(before: b, after: a, region: region)
            observable = true
        } else {
            fraction = 0
            observable = false
        }

        let verdict = PixelVerdict.decide(regionChangedFraction: fraction,
                                          observable: observable)
        let verified: Bool
        switch verdict {
        case .verified: verified = true
        case .dispatched: verified = false
        }

        return PixelOutcome(app: target.name, verb: verb, x: end.x, y: end.y,
                            dispatched: true, verified: verified,
                            observable: observable, changedFraction: fraction,
                            mode: mode)
    }

    /// The number of interpolated drag steps (some targets ignore a single jump).
    static let dragSteps = 8

    /// Synthesize and POST the mouse event sequence for a poke.
    ///
    /// `.invisible` (default): deliver each event straight to `pid` via
    /// `CGEventPostToPid` — never the HID tap (which would warp the visible cursor
    /// and route by screen geometry). Cursor-less, background-capable best-effort.
    ///
    /// `.visible`: warp the REAL cursor to the point and post each event through
    /// the HID tap (`.cghidEventTap`) so the WindowServer runs its true hit-test
    /// and actuates the front window under the point. We save the cursor first and
    /// restore it after, then re-associate the mouse so the physical pointer
    /// recouples. This MOVES / flickers the visible cursor and lands on whatever
    /// window is frontmost under the point — it is the LABELLED, NOT-invisible
    /// exception.
    ///
    /// For a drag, both modes interpolate `.leftMouseDragged` events between the
    /// endpoints so a drag-and-drop target sees a continuous drag, not a jump.
    @MainActor
    static func postMouseSequence(start: CGPoint, end: CGPoint, pid: pid_t,
                                  isDrag: Bool, mode: PixelMode = .invisible) {
        switch mode {
        case .invisible:
            postMouseSequenceInvisible(start: start, end: end, pid: pid, isDrag: isDrag)
        case .visible:
            postMouseSequenceVisible(start: start, end: end, isDrag: isDrag)
        }
    }

    /// DEFAULT path: `CGEventPostToPid`, cursor-less, background-capable best-effort.
    @MainActor
    private static func postMouseSequenceInvisible(start: CGPoint, end: CGPoint,
                                                   pid: pid_t, isDrag: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)

        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                              mouseCursorPosition: start, mouseButton: .left) {
            down.postToPid(pid)
        }

        if isDrag {
            for p in PixelPath.interpolate(start: start, end: end, steps: dragSteps) {
                if let moved = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged,
                                       mouseCursorPosition: p, mouseButton: .left) {
                    moved.postToPid(pid)
                }
            }
        }

        if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                            mouseCursorPosition: end, mouseButton: .left) {
            up.postToPid(pid)
        }
    }

    /// LABELLED exception: warp the real cursor + post through `.cghidEventTap` so
    /// the WindowServer hit-tests the front window under the point. Saves/restores
    /// the cursor and re-associates the mouse afterwards. NOT invisible.
    @MainActor
    private static func postMouseSequenceVisible(start: CGPoint, end: CGPoint, isDrag: Bool) {
        // Remember where the real pointer is so we can put it back.
        let savedPos = CGEvent(source: nil)?.location ?? start
        let src = CGEventSource(stateID: .hidSystemState)

        // Warp to the press point, then post the down through the HID tap. After a
        // warp the HID cursor is briefly decoupled from physical movement; a tiny
        // settle (and re-association on restore) lets the event post at the warped
        // point — the standard warp-then-post mitigation.
        warp(to: start)
        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                              mouseCursorPosition: start, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }

        if isDrag {
            for p in PixelPath.interpolate(start: start, end: end, steps: dragSteps) {
                warp(to: p)
                if let moved = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged,
                                       mouseCursorPosition: p, mouseButton: .left) {
                    moved.post(tap: .cghidEventTap)
                }
            }
        }

        warp(to: end)
        if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                            mouseCursorPosition: end, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }

        // Put the real pointer back and recouple it to physical movement.
        CGWarpMouseCursorPosition(savedPos)
        CGAssociateMouseAndMouseCursorPosition(1)   // boolean_t (true)
    }

    /// Warp the on-screen cursor to `p` and settle briefly so the next HID-tap
    /// post lands at the warped point (warp decouples the cursor momentarily).
    @MainActor
    private static func warp(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)   // boolean_t (true)
        usleep(8000)   // ~8ms — the standard warp-then-post settle.
    }

    static func rectString(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }
}

/// The window-capture helper for the pixel diff. Reuses the `shot`
/// ScreenCaptureKit path (CGWindowID → SCWindow → desktop-independent capture)
/// but returns a raw RGBA `PixelBuffer` for the PURE diff instead of writing a
/// PNG. Returns nil on ANY failure (no permission, window gone, capture error)
/// — the caller treats nil as "could not observe" ⇒ DISPATCHED-UNVERIFIED,
/// never an inferred change.
enum PixelCapture {
    @MainActor
    static func captureWindow(cgWindowID: CGWindowID?) async -> PixelBuffer? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let cgWindowID else { return nil }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            return nil
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == cgWindowID }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width)
        config.height = Int(scWindow.frame.height)
        // HONESTY: exclude the system cursor from the capture. It defaults to ON,
        // and the cursor commonly sits parked over the just-poked region; its
        // presence, blink, or animation between the before/after frames would
        // fabricate a pixel diff → a false VERIFIED with no real click effect.
        // The verdict must reflect the APP's repaint, not the pointer.
        config.showsCursor = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
        return rgbaBuffer(from: image)
    }

    /// Render a `CGImage` into a tightly-packed RGBA byte buffer (no row padding)
    /// so the pure diff compares apples to apples. Returns nil if the bitmap
    /// context can't be made or the image is empty.
    static func rgbaBuffer(from image: CGImage) -> PixelBuffer? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: info) else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return PixelBuffer(width: w, height: h, bytes: bytes)
    }
}
