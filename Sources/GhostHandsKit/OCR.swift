import AppKit
import AXorcist
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

// The UNIVERSAL fallback eye (issue #1). When a surface exposes neither AX nor a
// DOM (a canvas, a game, a remote screen, a stubborn custom UI), we screenshot the
// window and run Apple Vision OCR to recover on-screen TEXT + where it sits, so a
// brain can still locate a target. `ocr` is the read; `ocr-click` finds a phrase and
// clicks its center via the VISIBLE HID path (cursor moves — the labelled exception)
// verified by the pixel-diff `click-at` already enforces.
//
// HONESTY: this is the weakest tier on purpose. OCR can misread, so `ocr-click`
// REFUSES when no text matches (never clicks a guess) and the click still must show
// an observed pixel change to read VERIFIED. Vision is a SYSTEM framework — no new
// SwiftPM dependency.

public struct OCRItem: Sendable, Equatable {
    public let text: String
    /// On-screen rect, top-left origin, points (ready for an HID click / `click-at`).
    public let screenRect: CGRect
    public let confidence: Float

    public init(text: String, screenRect: CGRect, confidence: Float) {
        self.text = text
        self.screenRect = screenRect
        self.confidence = confidence
    }

    public var center: CGPoint { CGPoint(x: screenRect.midX, y: screenRect.midY) }
}

// MARK: - Pure: coordinate mapping

public enum OCRGeometry {
    /// A Vision `boundingBox` (NORMALIZED [0,1], BOTTOM-left origin, relative to the
    /// captured window image) → a SCREEN rect (top-left origin, points) using the
    /// window's on-screen frame. Normalized input means this is scale-independent —
    /// Retina 2× capture needs no special handling. The y-axis is flipped
    /// (bottom-left → top-left) so the rect lines up with CGEvent / AX screen coords.
    public static func screenRect(normBox b: CGRect, windowFrame f: CGRect) -> CGRect {
        let w = b.width * f.width
        let h = b.height * f.height
        let x = f.minX + b.minX * f.width
        let y = f.minY + (1 - b.minY - b.height) * f.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Pure: text matching (exact beats substring; ambiguity refuses)

public enum OCRMatch {
    public enum Choice: Equatable {
        case one(Int)
        case none
        case ambiguous([Int])
    }

    /// Pick the recognized line a query names. EXACT (case-insensitive, trimmed)
    /// wins; else substring; >1 with no exact hit is AMBIGUOUS (refuse, never guess).
    /// Mirrors `MenuMatch` so the locator behaves the same across tiers.
    public static func choose(_ texts: [String], query: String) -> Choice {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let norm = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let exact = norm.indices.filter { norm[$0] == q }
        if exact.count == 1 { return .one(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let subs = norm.indices.filter { !norm[$0].isEmpty && norm[$0].contains(q) }
        if subs.count == 1 { return .one(subs[0]) }
        if subs.count > 1 { return .ambiguous(subs) }
        return .none
    }
}

// MARK: - Impure: capture + Vision

extension GhostHands {
    /// `ocr <app>` — screenshot the app's front window and run Vision text
    /// recognition, returning every recognized line with its on-screen rect. Pure
    /// read (a screenshot + OCR; no actuation). Needs Screen Recording (like `shot`);
    /// refuses honestly without it.
    @MainActor
    public static func ocr(appSpec: String) async throws -> [OCRItem] {
        // Bootstrap the WindowServer connection (same reason as `shot`/pixel): CGS /
        // ScreenCaptureKit calls abort uncatchably (CGS_REQUIRE_INIT) from a bare
        // CLI without it. Stays a background accessory — no focus steal, no cursor.
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else {
            throw GhostHandsError.screenRecordingNotTrusted
        }
        let target = try Target.resolve(appSpec)
        guard let axWindow = (target.element.windows() ?? []).first else {
            throw GhostHandsError.noWindows(app: target.name)
        }
        guard let cgWindowID = AXWindowResolver().windowID(from: axWindow) else {
            throw GhostHandsError.captureFailed(reason: "could not resolve a CGWindowID")
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.current }
        catch { throw GhostHandsError.screenRecordingNotTrusted }
        guard let scWindow = content.windows.first(where: { $0.windowID == cgWindowID }) else {
            throw GhostHandsError.captureFailed(reason: "window not in the capturable set")
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

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) }
        catch { throw GhostHandsError.captureFailed(reason: "OCR failed: \(error.localizedDescription)") }

        let observations = (request.results) ?? []
        return observations.compactMap { obs -> OCRItem? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return OCRItem(
                text: candidate.string,
                screenRect: OCRGeometry.screenRect(normBox: obs.boundingBox,
                                                   windowFrame: scWindow.frame),
                confidence: candidate.confidence)
        }
    }

    /// `ocr-click "<text>" <app>` — OCR the window, find the phrase, and click its
    /// center via the VISIBLE HID path (cursor moves — labelled exception), verified
    /// by the screenshot-diff `click-at` enforces. REFUSES when no line matches
    /// (never clicks a guessed point) or when >1 matches with no exact hit.
    @MainActor
    public static func ocrClick(text query: String, appSpec: String,
                                settle: TimeInterval = 0.12) async throws -> PixelOutcome {
        let items = try await ocr(appSpec: appSpec)
        switch OCRMatch.choose(items.map { $0.text }, query: query) {
        case .none:
            throw GhostHandsError.ocrTextNotFound(
                query: query, app: appSpec, found: items.map { $0.text })
        case let .ambiguous(idxs):
            throw GhostHandsError.ambiguousMatch(name: query, candidates: idxs.map { items[$0].text })
        case let .one(i):
            let c = items[i].center
            return try await clickAt(x: Double(c.x), y: Double(c.y), appSpec: appSpec,
                                     mode: .visible, settle: settle)
        }
    }
}
