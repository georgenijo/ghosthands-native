import XCTest
@testable import GhostHandsKit

/// Hermetic — the honesty surface for `clipboard write`, with FABRICATED
/// intended/read-back strings (NO global pasteboard mutation; the live
/// NSPasteboard read/write is the impure half and is deliberately untested). The
/// single invariant: a write is VERIFIED only when the pasteboard READ BACK
/// exactly the intended value — the NSPasteboard `setString` boolean is never
/// consulted, so a set that AppKit "accepted" but did not observably land is
/// dispatched-unverified, never a faked success.
final class ClipboardVerdictTests: XCTestCase {
    private func decide(_ intended: String, _ readback: String?) -> ClipboardVerdict.Result {
        ClipboardVerdict.write(intended: intended, readback: readback)
    }

    // MARK: equal read-back → verified (the only success)

    func testEqualReadbackVerified() {
        // The pasteboard read back exactly what we wrote → observed set → verified.
        XCTAssertEqual(decide("hello", "hello"), .verified)
    }

    func testEqualReadbackEmptyStringVerified() {
        // Writing "" and reading back "" is a legitimate observed set of an empty
        // string (distinct from a nil/absent pasteboard) → verified.
        XCTAssertEqual(decide("", ""), .verified)
    }

    func testEqualReadbackUnicodeVerified() {
        // Multi-byte UTF-8 round-trips by value equality, not byte count.
        XCTAssertEqual(decide("héllo 🌍", "héllo 🌍"), .verified)
    }

    // MARK: unequal read-back → dispatched (never faked)

    func testDifferentReadbackDispatched() {
        // Another process clobbered the pasteboard between our set and read-back, or
        // an owner transformed it — the value differs → dispatched, NEVER verified.
        XCTAssertEqual(decide("hello", "goodbye"), .dispatched)
    }

    func testAbsentReadbackDispatched() {
        // A nil read-back (the pasteboard holds no string) can never equal a write
        // we dispatched → dispatched-unverified.
        XCTAssertEqual(decide("hello", nil), .dispatched)
    }

    func testEmptyReadbackForNonEmptyWriteDispatched() {
        // Wrote a real string but the pasteboard read back empty → the set did not
        // land observably → dispatched.
        XCTAssertEqual(decide("hello", ""), .dispatched)
    }

    func testNonEmptyReadbackForEmptyWriteDispatched() {
        // Wrote "" but the pasteboard still holds an old value → not observed →
        // dispatched (never claim the clear landed).
        XCTAssertEqual(decide("", "stale"), .dispatched)
    }

    func testCaseSensitiveMismatchDispatched() {
        // The clipboard is an exact byte channel — a case difference is a real
        // mismatch, not a "moved toward" (clipboard has no normalisation tier).
        XCTAssertEqual(decide("Hello", "hello"), .dispatched)
    }

    func testWhitespaceMismatchDispatched() {
        // Trailing whitespace differs → not equal → dispatched (no trimming).
        XCTAssertEqual(decide("hi", "hi "), .dispatched)
    }
}
