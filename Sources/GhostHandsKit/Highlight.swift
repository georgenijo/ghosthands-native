import AppKit
import AXorcist
import Foundation

// An OPT-IN visual overlay: flash a highlight box at the on-screen frame of the
// element a verb is about to act on, so a human can SEE where ghosthands is working
// — WITHOUT moving the real cursor or stealing focus (the invisibility contract is
// intact). It's a transparent, click-through, non-activating panel drawn above
// everything for a beat, then faded out. This is observability, not actuation: it
// shows where the AX target IS; it is NOT a fake mouse pointer and never clicks.
//
// Enabled by `GHOSTHANDS_HIGHLIGHT=1` (env, so it applies across CLI + MCP without
// touching each call). Off by default → zero cost, no AppKit window ever created.

public enum Highlight {
    /// Opt-in via env. Off → the flash is never invoked, so a normal run pays
    /// nothing (no NSApplication/NSWindow is touched).
    public static var isEnabled: Bool {
        guard let v = ProcessInfo.processInfo.environment["GHOSTHANDS_HIGHLIGHT"] else {
            return false
        }
        let s = v.lowercased()
        return s == "1" || s == "true" || s == "yes"
    }

    /// PURE coordinate flip: an AX rect (global, TOP-left origin, y down) → a Cocoa
    /// rect (global, BOTTOM-left origin, y up). Both systems are anchored to the
    /// primary display, so the only transform is mirroring y about the primary
    /// screen's height. Unit-tested without any screen.
    public static func cocoaRect(forAX axRect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: axRect.minX,
               y: primaryHeight - axRect.minY - axRect.height,
               width: axRect.width, height: axRect.height)
    }

    /// Flash a highlight box at `axRect` (AX/global coords) for `duration` seconds,
    /// then fade. No-op for a zero/empty rect (an unreadable frame → nothing
    /// fabricated). Runs the runloop briefly so the panel actually paints before the
    /// short-lived CLI returns; the cost is paid ONLY when highlighting is enabled.
    @MainActor
    public static func flash(_ axRect: CGRect, duration: TimeInterval = 0.6) {
        guard axRect.width > 1, axRect.height > 1 else { return }
        let appKit = NSApplication.shared
        // .accessory: a faceless GUI process — can draw windows with NO dock icon
        // and NO focus steal (we never call activate()).
        if appKit.activationPolicy() != .accessory { appKit.setActivationPolicy(.accessory) }

        // The primary display (origin (0,0)) defines the global coordinate flip.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
        guard let primaryHeight = primary?.frame.height else { return }
        let cocoa = cocoaRect(forAX: axRect, primaryHeight: primaryHeight)

        let panel = NSPanel(contentRect: cocoa,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver            // above app windows + menus
        panel.ignoresMouseEvents = true       // click-through — never intercepts input
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let box = NSView(frame: NSRect(origin: .zero, size: cocoa.size))
        box.wantsLayer = true
        box.layer?.borderColor = NSColor.systemRed.cgColor
        box.layer?.borderWidth = 4
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.16).cgColor
        panel.contentView = box
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()          // show WITHOUT activating (no focus steal)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18; panel.animator().alphaValue = 1.0
        }
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3; panel.animator().alphaValue = 0.0
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.32))
        panel.orderOut(nil)
    }

    /// Convenience for the act verbs: when highlighting is enabled and the element
    /// exposes a readable frame, flash it. A no-op otherwise (off, or no frame — we
    /// never fabricate a box). Call right before the actuation so the box marks the
    /// control about to be driven.
    @MainActor
    public static func flashIfEnabled(_ element: Element) {
        guard isEnabled, let frame = element.frame() else { return }
        flash(frame)
    }
}
