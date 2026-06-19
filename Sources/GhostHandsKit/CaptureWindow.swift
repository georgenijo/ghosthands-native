import Foundation

// Shared capture-window resolution for `ocr` + `shot`. Both need to turn a target
// app into ONE capturable on-screen window. The old path bridged the app's AX
// window → CGWindowID via a private shim and REFUSED when that returned nil — which
// it does for background / degenerate windows (macOS-26 exposes them), so the OCR
// eye + `shot` failed with "could not resolve a CGWindowID" on perfectly real,
// visible windows.
//
// The robust path keeps the AX bridge as a PREFERRED exact match but FALLS BACK to
// the app's own windows in ScreenCaptureKit's capturable set, matched by PID — no
// AX bridge needed. The window PICK is pure (rank fabricated candidates) so it is
// hermetically testable; the impure mapping from `SCWindow` lives in `ocr`/`shot`.
//
// HONESTY: it only ever picks a REAL window that BELONGS to the target app (PID
// match) — never another app's window, never a fabricated one. If the app has no
// capturable window at all, the caller REFUSES honestly. For a READ (screenshot /
// OCR), picking the app's main on-screen window is the intent.

/// One capturable window, projected from `SCWindow` to the few facts the pick
/// needs — so the ranking is testable with fabricated values (no live capture).
public struct CaptureCandidate: Sendable, Equatable {
    public let windowID: UInt32
    public let pid: pid_t
    /// On-screen pixel area (width × height) — bigger ⇒ more likely the main window.
    public let area: Double
    /// The window layer: 0 is a normal app window; higher layers are panels /
    /// overlays / menus we deprioritise.
    public let layer: Int
    /// Whether ScreenCaptureKit reports the window as currently on screen.
    public let onScreen: Bool

    public init(windowID: UInt32, pid: pid_t, area: Double, layer: Int, onScreen: Bool) {
        self.windowID = windowID
        self.pid = pid
        self.area = area
        self.layer = layer
        self.onScreen = onScreen
    }
}

public enum CaptureWindowPick {
    /// Choose the window id to capture for `pid`.
    ///
    /// 1. If the AX-bridged `preferred` id is present in the set AND belongs to the
    ///    app, use it (the exact AX→CG match, when the bridge worked).
    /// 2. Otherwise fall back to the app's OWN windows, ranked: on-screen first,
    ///    then a normal (layer 0) window, then the largest area — i.e. the main
    ///    window a human would call "the app's window".
    ///
    /// Returns nil only when NO capturable window belongs to the app (the caller
    /// REFUSES honestly). Never returns another app's window.
    public static func choose(_ candidates: [CaptureCandidate], pid: pid_t,
                              preferred: UInt32?) -> UInt32? {
        if let preferred,
           candidates.contains(where: { $0.windowID == preferred && $0.pid == pid }) {
            return preferred
        }
        let mine = candidates.filter { $0.pid == pid }
        guard !mine.isEmpty else { return nil }
        let ranked = mine.sorted { a, b in
            if a.onScreen != b.onScreen { return a.onScreen }          // on-screen first
            if (a.layer == 0) != (b.layer == 0) { return a.layer == 0 } // normal window first
            if a.area != b.area { return a.area > b.area }              // largest first
            return a.windowID < b.windowID                             // stable tiebreak
        }
        return ranked.first?.windowID
    }
}
