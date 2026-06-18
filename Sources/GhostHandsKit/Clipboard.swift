import AppKit
import Foundation

/// The CLIPBOARD tier — `clipboard read` / `clipboard write <text>`.
///
/// A model-free, AX-free verb over `NSPasteboard.general` (AppKit). No element
/// resolution, no synthetic events, no cursor — just the system pasteboard.
///
/// HONESTY (the load-bearing decision, mirroring `type`/`set-value`):
/// `setString(_:forType:)` returning `true` means AppKit ACCEPTED the write; it
/// is NOT, by itself, proof the pasteboard now holds the value (another process
/// can win a race, a pasteboard owner can transform/clear it). So `write` NEVER
/// trusts that boolean — it READS THE VALUE BACK off the live pasteboard and
/// hands the read-back to the PURE `ClipboardVerdict.write` decider:
/// - read-back == intended → VERIFIED ("clipboard set, read back N chars"),
/// - read-back != intended → DISPATCHED-UNVERIFIED (the set was accepted but the
///   observed value differs / is absent) — NEVER a faked success.
///
/// `read` is a pure observation: print the live pasteboard string verbatim. An
/// empty or absent string is NOT fabricated — we print nothing and emit an honest
/// stderr note, exit 0.
///
/// The pure verdict (`ClipboardVerdict`) is hermetically unit-tested over
/// fabricated strings; the live `NSPasteboard` read/write here is the impure half
/// and is NOT exercised by the tests (a test must never mutate the global
/// pasteboard) — exactly the project's pure-decider-only convention.

/// The honest outcome of a `clipboard write`. `readback` is the value re-read off
/// the live pasteboard AFTER the set (nil = empty/absent); `verified` is computed
/// by `ClipboardVerdict.write` from the read-back ALONE, NEVER from the AppKit
/// `setString` boolean.
public struct ClipboardOutcome: Sendable, Equatable {
    /// The text we asked the pasteboard to hold.
    public let intended: String
    /// The value re-read off the live pasteboard after the set (nil = empty/absent).
    public let readback: String?
    /// True only when the read-back equals the intended value (observed change).
    public let verified: Bool

    public init(intended: String, readback: String?, verified: Bool) {
        self.intended = intended
        self.readback = readback
        self.verified = verified
    }
}

/// The PURE verdict for the clipboard write. Sees ONLY the value we intended and
/// the value the pasteboard READ BACK — never the `setString` boolean. The
/// read-back is the sole arbiter: equal → verified, anything else → dispatched.
/// Kept AppKit-free so the honesty guard is hermetically testable on fabricated
/// strings (mirrors `ValueVerdict`/`FocusVerdict`).
public enum ClipboardVerdict {
    public enum Result: Sendable, Equatable {
        /// The pasteboard READ BACK exactly the intended value — an observed set.
        case verified
        /// The set was accepted but the read-back differs / is absent — honest
        /// under-claim, never a success claim.
        case dispatched
    }

    /// `intended == readback` → VERIFIED, else DISPATCHED-UNVERIFIED.
    ///
    /// A nil read-back (empty/absent pasteboard) can NEVER equal a write we
    /// dispatched (the caller only ever writes a concrete string), so it is always
    /// dispatched — the set did not land observably. Two distinct strings (the
    /// pasteboard holds something else, e.g. another process clobbered it) are
    /// likewise dispatched, never faked.
    public static func write(intended: String, readback: String?) -> Result {
        readback == intended ? .verified : .dispatched
    }
}

extension GhostHands {
    /// `clipboard read` — return the live pasteboard string verbatim (UTF-8), or
    /// `nil` when the pasteboard holds no string (empty/absent). The impure half:
    /// reads `NSPasteboard.general`. NEVER fabricates a value.
    @MainActor
    public static func clipboardRead() -> String? {
        // Bootstrap AppKit as a background accessory (no focus steal, no cursor) —
        // the same reason the pixel/key tiers touch NSApplication.shared.
        _ = NSApplication.shared
        return NSPasteboard.general.string(forType: .string)
    }

    /// `clipboard write <text>` — set the pasteboard string, then READ IT BACK and
    /// hand the read-back to the pure verdict. The impure half: clears + writes
    /// `NSPasteboard.general`, then re-reads it. Returns an honest outcome —
    /// VERIFIED only when the read-back equals `text`, else dispatched-unverified.
    @MainActor
    public static func clipboardWrite(text: String) -> ClipboardOutcome {
        _ = NSApplication.shared
        let pb = NSPasteboard.general
        // clearContents() takes ownership and is the standard idiom before a write;
        // we do NOT trust its / setString's boolean — the read-back is the arbiter.
        pb.clearContents()
        _ = pb.setString(text, forType: .string)

        // Re-read off the live pasteboard — the SOLE evidence of the set.
        let readback = pb.string(forType: .string)
        let verdict = ClipboardVerdict.write(intended: text, readback: readback)
        return ClipboardOutcome(intended: text, readback: readback,
                                verified: verdict == .verified)
    }
}
