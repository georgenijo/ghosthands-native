import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation

/// The KEY ACTUATION tier — `key <spec> [app] [--visible]`.
///
/// This closes the "no way to press Enter to submit a web search" gap: post a
/// keystroke or chord to an app. The pure parse (name→keycode, token→flag,
/// chord-combine) lives in `KeySpec.swift`; THIS file is the impure half — it
/// builds the CGEvent key-down/up pair and posts it — and is NOT exercised by the
/// hermetic tests (exactly like `postMouseSequence` is excluded from the pixel
/// tests).
///
/// HONESTY (the load-bearing decision): a key event has NO built-in observable —
/// no AX value, and unlike a pixel poke there is no caller-supplied target point
/// to screenshot-diff. The keystroke's effect lands wherever the app routes it.
/// So `key` is ALWAYS dispatched-unverified, in BOTH modes — the closest analogue
/// is `window raise` ("dispatched; not observable → unverified, never faked"),
/// NOT `click-at` (which has a diff). We do NOT reuse the screenshot-diff path.
///
/// INVISIBILITY (the same axis as the pixel tier, reusing `PixelMode`):
///
/// - `.invisible` (DEFAULT): build the key events with `CGEvent(keyboardEventSource:…)`
///   and deliver them straight to the TARGET app's pid via `CGEventPostToPid` —
///   cursor-less, no focus steal, background-capable BEST-EFFORT. HONESTY:
///   `postToPid` is delivery-only and macOS may NOT route a key to a non-focused /
///   background app (the SAME OS wall the pixel `postToPid` hits). We NEVER promise
///   background key delivery; the verdict is always dispatched-unverified.
///
/// - `.visible` (LABELLED exception): when an app spec is given, ACTIVATE it first
///   to take focus, then post through the HID tap (`.cghidEventTap`) so the focused
///   app receives the key like a real keypress — the path for when the invisible
///   post does not land. Trade-off, stated plainly: NOT invisible, may FOREGROUND /
///   steal focus, and the key goes to whatever app is focused (an OS wall); it
///   cannot key a truly background app without activating it.
extension GhostHands {
    /// `key <spec> [app] [--visible]` — post a keystroke/chord. The app spec is
    /// OPTIONAL: with no app, post via the HID tap to the FRONTMOST app (the
    /// focused one); with an app, default to the invisible per-pid post. Parses
    /// the spec FIRST (so a bad spec REFUSES cheaply, before resolving the app),
    /// then dispatches. Returns an outcome that is honest: dispatched-unverified.
    @MainActor
    public static func key(spec: String, appSpec: String?,
                           mode: KeyMode = .invisible) throws -> KeyOutcome {
        // Bootstrap the connection (same reason as the pixel tier): a background
        // accessory — no focus steal, no cursor.
        _ = NSApplication.shared

        // Parse FIRST — before the permission gate AND before resolving the app:
        // a bad spec / unknown key REFUSES cheaply (throws .badKeySpec /
        // .unknownKey) even on an un-trusted machine, without touching a live app.
        let parsed = try KeySpec.parse(spec)

        // Synthetic event posting requires the Accessibility grant; without it the
        // post silently no-ops, so gate before any post like the pixel/AX verbs.
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }

        // Resolve the destination. With an app spec, target its pid. Without one,
        // there is no pid to post to; we fall back to the HID tap on the frontmost
        // app, which is the `.visible` path by definition (the focused app
        // receives it). The default invisible per-pid post REQUIRES an app spec.
        let target: Target? = try appSpec.map { try Target.resolve($0) }
        let appName = target?.name ?? "frontmost"

        // Without an app spec there is no pid to post-to-pid; route through the HID
        // tap to the focused app. This is the labelled visible path (it goes to
        // whatever app is focused), so reflect that in the reported mode.
        let effectiveMode: KeyMode = (target == nil) ? .visible : mode

        switch effectiveMode {
        case .invisible:
            // DEFAULT: post straight to the target pid (cursor-less, background
            // best-effort). target is non-nil here (invisible requires an app).
            if let pid = target?.pid {
                postKeyInvisible(keyCode: parsed.keyCode, flags: parsed.flags, pid: pid)
            }
        case .visible:
            // LABELLED exception: focus the app (if we have one) then post through
            // the HID tap so the focused app receives a real keypress.
            target?.app.activate(options: [.activateIgnoringOtherApps])
            postKeyVisible(keyCode: parsed.keyCode, flags: parsed.flags)
        }

        return KeyOutcome(app: appName, spec: parsed.name, keyName: parsed.name,
                          mode: effectiveMode, dispatched: true,
                          verified: false, observable: false)
    }

    /// DEFAULT path: build the key-down/up pair and deliver each straight to `pid`
    /// via `CGEventPostToPid` — cursor-less, no focus steal, background-capable
    /// best-effort. The `.flags` field carries the chord modifiers; no separate
    /// modifier key events are needed for synthetic CGEvents (the standard idiom).
    @MainActor
    private static func postKeyInvisible(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.postToPid(pid)
        }
    }

    /// LABELLED exception: post the key-down/up pair through `.cghidEventTap` so
    /// the FOCUSED app receives the key like a real keypress. The caller activates
    /// the target app first (when there is one) so focus lands where intended.
    /// NOT invisible — the key goes to whatever app is focused.
    @MainActor
    private static func postKeyVisible(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}
