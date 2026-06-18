import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The `shot` verb — an HONEST screenshot.
///
/// AXorcist has zero capture capability, so this uses macOS-native
/// ScreenCaptureKit (`SCScreenshotManager`, macOS 14+). The whole point is the
/// permission gate: without Screen Recording the OS returns a BLACK image with
/// no error, so we preflight with `CGPreflightScreenCaptureAccess()` and REFUSE
/// (no file written) when it is false. A file on disk only ever means real
/// captured pixels — there is deliberately NO dispatched/half state for `shot`.
public enum Shot {
    /// The pure refusal decision: a function of two booleans, so the honesty
    /// gate is unit-testable with no capture. `hasWindow` is whether the target
    /// app has at least one capturable window.
    public enum Decision: Sendable, Equatable {
        case allow
        case refuseNoPermission
        case refuseNoWindow
    }

    public static func decide(hasScreenRecording: Bool, hasWindow: Bool) -> Decision {
        guard hasScreenRecording else { return .refuseNoPermission }   // permission first
        guard hasWindow else { return .refuseNoWindow }
        return .allow
    }

    /// Encode a captured CGImage to PNG on disk. Returns false (writes nothing)
    /// if the image has no pixels (zero dimensions) — the last honesty guard
    /// before claiming a file was written. NOTE: this proves real DIMENSIONS,
    /// not real CONTENT; a granted capture of a minimized/off-screen window can
    /// still return an all-black image of valid size. We do not scan pixels for
    /// black (expensive and fragile), so `shot`'s guarantee is "a file means a
    /// real, permission-backed capture of the window," not "the pixels are
    /// non-black." A window-scoped `desktopIndependentWindow` capture renders the
    /// window's own content even when occluded, so black is confined to the
    /// minimized/off-screen case.
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard image.width > 0, image.height > 0 else { return false }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Best-effort FULL-SCREEN (main display) capture for the failure-artifacts
    /// side-channel, reusing the same ScreenCaptureKit + `writePNG` machinery as
    /// the `shot` verb. Unlike `shot`, this NEVER throws and NEVER refuses: it is
    /// pure forensics. It returns the written path on success and `nil` on ANY
    /// shortfall (no Screen-Recording grant, no display, capture error, an empty
    /// image, or an encode failure) so the caller logs `screenshotPath: null`
    /// rather than failing. It captures the whole main display (not a window) so
    /// the artifact shows the screen state at the moment of the refuse regardless
    /// of which app — if any — the verb was targeting.
    ///
    /// NOT `@MainActor`: SCK's capture entry points are queue-backed and safe off
    /// the main thread. The ONLY main-thread requirement is the one-time CGS
    /// (WindowServer) connection bootstrap (`NSApplication.shared`), which the
    /// caller performs on the main thread BEFORE invoking this from a background
    /// task — so this can run while the main thread is blocked awaiting it
    /// without a main-actor deadlock.
    static func captureMainDisplayPNG(to url: URL) async -> String? {
        // Permission gate (non-prompting) — without it the OS returns a black
        // image; a refused grant means no artifact screenshot, never a black PNG.
        guard CGPreflightScreenCaptureAccess() else { return nil }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            return nil
        }
        // The main display = the one carrying the menu bar (CGMainDisplayID).
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays.first else {
            return nil
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = true   // forensic: show where the pointer was

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
        guard writePNG(image, to: url) else { return nil }
        return url.path
    }
}

extension GhostHands {
    public struct ShotOutcome: Sendable {
        public let app: String
        public let path: String
        public let width: Int
        public let height: Int
    }

    /// Capture the target app's frontmost window to `outPath` (PNG).
    ///
    /// Honesty contract:
    /// - REFUSE (`.screenRecordingNotTrusted`, no file) if Screen Recording is
    ///   not granted — checked via the non-prompting `CGPreflightScreenCaptureAccess`.
    ///   We never call the prompting variant: a read verb must not raise dialogs.
    /// - REFUSE (`.noWindows`) if the app exposes no AX window.
    /// - REFUSE (`.captureFailed`, no file) if capture returns an empty image
    ///   despite the grant (occluded/off-screen) — never a blank PNG as success.
    /// - Otherwise write the PNG and return its real dimensions.
    @MainActor
    public static func shot(appSpec: String, outPath: String) async throws -> ShotOutcome {
        // ScreenCaptureKit and the CoreGraphics window APIs (incl.
        // CGPreflightScreenCaptureAccess) require a WindowServer (CGS)
        // connection. A bare CLI process has not established one, so the first
        // such call aborts the process with the uncatchable
        // `Assertion failed: (did_initialize) … CGS_REQUIRE_INIT`. A crash is the
        // opposite of the honesty contract, so we bootstrap the connection by
        // instantiating the shared NSApplication — its init connects to the
        // WindowServer. We never call run()/activate()/finishLaunching, so the
        // app stays a background accessory (no focus steal, no cursor move, no
        // Dock icon), turning the abort into either a real capture or a clean,
        // honest refuse.
        _ = NSApplication.shared

        // Permission gate FIRST — non-prompting. Without it the OS hands back a
        // black image with no error, so this is the only reliable honest check.
        guard CGPreflightScreenCaptureAccess() else {
            throw GhostHandsError.screenRecordingNotTrusted
        }
        // AX is a SEPARATE permission; we still need it to resolve the window.
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }

        let target = try Target.resolve(appSpec)
        let windows = target.element.windows() ?? []

        // Drive the (unit-tested) honesty gate from the REAL booleans, so the
        // function under test is the one that actually runs — not a pair of
        // hardcoded literals after the guards (which made the refuse arms dead
        // code). `CGPreflightScreenCaptureAccess` was already checked above, but
        // re-reading it here keeps `decide` the single source of the decision.
        switch Shot.decide(hasScreenRecording: CGPreflightScreenCaptureAccess(),
                           hasWindow: !windows.isEmpty) {
        case .refuseNoPermission: throw GhostHandsError.screenRecordingNotTrusted
        case .refuseNoWindow: throw GhostHandsError.noWindows(app: target.name)
        case .allow: break
        }
        let axWindow = windows[0]

        // Bridge the AX window to a CGWindowID via the MIT dependency's private
        // _AXUIElementGetWindow shim, then to an SCWindow for a window-scoped,
        // desktop-independent capture (no other window's pixels bleed in).
        let resolver = AXWindowResolver()
        guard let cgWindowID = resolver.windowID(from: axWindow) else {
            throw GhostHandsError.captureFailed(reason: "could not resolve a CGWindowID for the window")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            // Content enumeration itself throws when Screen Recording is denied —
            // a second honest failure point.
            throw GhostHandsError.screenRecordingNotTrusted
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == cgWindowID }) else {
            throw GhostHandsError.captureFailed(reason: "window not present in the capturable set")
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width)
        config.height = Int(scWindow.frame.height)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            throw GhostHandsError.captureFailed(reason: "\(error.localizedDescription)")
        }

        let url = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
        guard Shot.writePNG(image, to: url) else {
            // Empty image despite the grant (occluded/off-screen). REFUSE rather
            // than write a blank PNG — same honesty rule as no-permission.
            throw GhostHandsError.captureFailed(
                reason: "captured image was empty (window may be off-screen or occluded)")
        }

        return ShotOutcome(app: target.name, path: url.path,
                           width: image.width, height: image.height)
    }
}
