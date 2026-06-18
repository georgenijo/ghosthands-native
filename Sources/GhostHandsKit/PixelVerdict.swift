import CoreGraphics
import Foundation

/// The PURE honesty core of the pixel-actuation tier — no CGEvent, no capture,
/// no live app. A blind pixel poke has no AX element to read back, so the only
/// honest effect-witness is a SCREENSHOT DIFF: capture the target window before
/// and after the click and ask "did the pixels around the click point change?".
///
/// Everything here is a function of plain values (RGBA byte buffers, a changed
/// fraction, a threshold) so the whole VERIFIED/DISPATCHED decision is unit
/// testable on FABRICATED pixel buffers — a live capture NEVER appears in a test.
public enum PixelVerdict {
    /// The fraction of a region's pixels (0.0…1.0) that must differ for a poke to
    /// count as an OBSERVED change. Below this we under-claim (DISPATCHED), never
    /// success. A small but non-zero floor so sub-pixel capture jitter / a single
    /// stray byte does not fabricate a "verified" — a real click that lands on a
    /// button repaints a visible neighborhood, well above this.
    public static let defaultThreshold = 0.01

    public enum Result: Sendable, Equatable {
        /// The pixels in the diffed region changed by `fraction` (≥ threshold) —
        /// an observed world-change. Honest VERIFIED.
        case verified(fraction: Double)
        /// The click was dispatched but the region did not change enough to prove
        /// an effect — honest under-claim, NEVER reported as success. Carries the
        /// (sub-threshold) fraction and whether we could observe at all.
        case dispatched(fraction: Double, observable: Bool)
    }

    /// Decide the verdict from a measured changed-fraction and whether we were
    /// ABLE to observe (i.e. Screen Recording granted + both captures succeeded).
    ///
    /// - `observable == false`  → DISPATCHED-UNVERIFIED regardless of fraction:
    ///   we acted but could not look, so we cannot claim an effect. (fraction is
    ///   reported as 0 by convention since it was not measured.)
    /// - `observable == true` and `fraction >= threshold` → VERIFIED.
    /// - `observable == true` and `fraction <  threshold` → DISPATCHED (clicked,
    ///   no observable pixel change).
    ///
    /// This is the single source of the pixel honesty decision — the live verb
    /// drives it with the REAL measured fraction, never a hardcoded literal.
    public static func decide(regionChangedFraction fraction: Double,
                              threshold: Double = defaultThreshold,
                              observable: Bool = true) -> Result {
        guard observable else { return .dispatched(fraction: 0, observable: false) }
        if fraction >= threshold {
            return .verified(fraction: fraction)
        }
        return .dispatched(fraction: fraction, observable: true)
    }
}

/// A minimal, value-type abstraction over a raw RGBA pixel buffer so the diff is
/// testable on FABRICATED bytes (never a live `CGImage` in a test). Width/height
/// in pixels, `bytes` is row-major RGBA (4 bytes/pixel, no padding).
public struct PixelBuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]   // count == width * height * 4

    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public var isValid: Bool { width > 0 && height > 0 && bytes.count == width * height * 4 }
}

/// The PURE pixel-diff. Compares two equal-sized RGBA buffers over a clamped
/// region (a neighborhood around the click point) and returns the FRACTION of
/// pixels in that region whose color differs by more than `tolerance` per
/// channel. Returns 0.0 when the buffers are identical, when shapes mismatch
/// (cannot honestly compare → no evidence), or when the region is empty.
///
/// Kept free of CoreGraphics so it runs on hand-built buffers in a hermetic test.
public enum PixelDiff {
    /// Per-channel absolute difference above which a pixel counts as "changed".
    /// A small floor absorbs capture-pipeline noise (dithering, 1x downscale)
    /// without masking a real repaint.
    public static let defaultTolerance: UInt8 = 8

    /// `region` is in pixel coordinates within the buffers (top-left origin). It
    /// is clamped to the buffer bounds; an out-of-buffer or empty region yields 0.
    /// `before`/`after` must share width/height — a shape mismatch returns 0
    /// (we refuse to invent a change we cannot honestly measure).
    public static func changedFraction(before: PixelBuffer, after: PixelBuffer,
                                       region: PixelRegion,
                                       tolerance: UInt8 = defaultTolerance) -> Double {
        guard before.isValid, after.isValid,
              before.width == after.width, before.height == after.height else {
            return 0.0
        }
        let w = before.width
        let h = before.height

        // Clamp the region to the buffer.
        let x0 = max(0, region.x)
        let y0 = max(0, region.y)
        let x1 = min(w, region.x + region.width)
        let y1 = min(h, region.y + region.height)
        guard x1 > x0, y1 > y0 else { return 0.0 }

        var changed = 0
        var total = 0
        before.bytes.withUnsafeBufferPointer { b in
            after.bytes.withUnsafeBufferPointer { a in
                for y in y0..<y1 {
                    let row = y * w * 4
                    for x in x0..<x1 {
                        let i = row + x * 4
                        total += 1
                        // Compare R,G,B,A; any channel past tolerance => changed.
                        if absDiff(b[i], a[i]) > tolerance
                            || absDiff(b[i + 1], a[i + 1]) > tolerance
                            || absDiff(b[i + 2], a[i + 2]) > tolerance
                            || absDiff(b[i + 3], a[i + 3]) > tolerance {
                            changed += 1
                        }
                    }
                }
            }
        }
        return total == 0 ? 0.0 : Double(changed) / Double(total)
    }

    @inline(__always)
    private static func absDiff(_ a: UInt8, _ b: UInt8) -> Int {
        a > b ? Int(a) - Int(b) : Int(b) - Int(a)
    }
}

/// A pixel-space rectangle for the diff neighborhood. Plain value type so it is
/// usable in hermetic tests with no CoreGraphics.
public struct PixelRegion: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// A square of half-size `radius` centered on `(cx, cy)` in pixel space.
    /// Used to focus the diff on the click neighborhood rather than the whole
    /// window (a distant clock tick must not become false evidence).
    public static func centered(cx: Int, cy: Int, radius: Int) -> PixelRegion {
        let r = max(0, radius)
        return PixelRegion(x: cx - r, y: cy - r, width: 2 * r + 1, height: 2 * r + 1)
    }
}

/// The PURE bounds gate, mirroring `Shot.decide`'s pattern: REFUSE to poke a
/// point outside the target window (don't click a random place). A function of
/// the global click point and the window's global frame, so it is unit-testable
/// with no live window.
public enum PixelBounds {
    public enum Decision: Sendable, Equatable {
        case inside
        case outside
    }

    /// `point` and `frame` are both in GLOBAL top-left-origin screen coordinates.
    /// A point on the right/bottom edge is treated as outside (half-open rect),
    /// consistent with pixel addressing.
    public static func decide(point: CGPoint, windowFrame: CGRect) -> Decision {
        let inX = point.x >= windowFrame.minX && point.x < windowFrame.maxX
        let inY = point.y >= windowFrame.minY && point.y < windowFrame.maxY
        return (inX && inY) ? .inside : .outside
    }
}
