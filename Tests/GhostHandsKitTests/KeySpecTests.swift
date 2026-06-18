import CoreGraphics
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE key-spec parse + outcome honesty layer on FABRICATED
/// strings. NEVER posts a real key event or drives a live app (the env rule):
/// every input is a hand-built spec string. Mirrors `ActionVerdictTests`'s
/// `ActionName map` section (name→code table + unknown→refuse) and
/// `PixelVerdictTests`'s `--visible` parse + outcome-invariant sections.
final class KeySpecTests: XCTestCase {

    // MARK: KeyName.keyCode — name → keycode table (mirror friendly→AX map)

    // These literals are PINNED to the documented `kVK_*` constants in the system
    // <HIToolbox/Events.h> (Carbon) so a future table edit that breaks a code is
    // caught HERE rather than silently shipping a wrong key. The assertions are
    // against the spelled-out hex (NOT `KeyName.keyCode(...)`), so they are an
    // INDEPENDENT cross-check, not circular against the table under test.
    func testNamedKeysMapToANSIKeycodes() {
        XCTAssertEqual(KeyName.keyCode(for: "return"), 0x24)  // kVK_Return
        XCTAssertEqual(KeyName.keyCode(for: "enter"),  0x24)  // enter ALIASES return (kVK_Return)
        XCTAssertEqual(KeyName.keyCode(for: "tab"),    0x30)  // kVK_Tab
        XCTAssertEqual(KeyName.keyCode(for: "space"),  0x31)  // kVK_Space
        XCTAssertEqual(KeyName.keyCode(for: "escape"), 0x35)  // kVK_Escape
        XCTAssertEqual(KeyName.keyCode(for: "esc"),    0x35)  // alias (kVK_Escape)
        XCTAssertEqual(KeyName.keyCode(for: "delete"), 0x33)  // kVK_Delete (backspace)
        XCTAssertEqual(KeyName.keyCode(for: "backspace"), 0x33) // alias of delete (kVK_Delete)
        XCTAssertEqual(KeyName.keyCode(for: "up"),     0x7E)  // kVK_UpArrow
        XCTAssertEqual(KeyName.keyCode(for: "down"),   0x7D)  // kVK_DownArrow
        XCTAssertEqual(KeyName.keyCode(for: "left"),   0x7B)  // kVK_LeftArrow
        XCTAssertEqual(KeyName.keyCode(for: "right"),  0x7C)  // kVK_RightArrow
    }

    func testNamedKeysAreCaseInsensitive() {
        // Mirror testFriendlyActionsMapToAXStrings' case-insensitive arm.
        XCTAssertEqual(KeyName.keyCode(for: "ESC"),    0x35)
        XCTAssertEqual(KeyName.keyCode(for: "Return"), 0x24)
        XCTAssertEqual(KeyName.keyCode(for: "TAB"),    0x30)
    }

    // ANSI letter/digit codes pinned to <HIToolbox/Events.h> kVK_ANSI_* literals.
    func testLetterAndDigitMapToANSIKeycodes() {
        XCTAssertEqual(KeyName.keyCode(for: "a"), 0x00)        // kVK_ANSI_A
        XCTAssertEqual(KeyName.keyCode(for: "s"), 0x01)        // kVK_ANSI_S
        XCTAssertEqual(KeyName.keyCode(for: "t"), 0x11)        // kVK_ANSI_T
        XCTAssertEqual(KeyName.keyCode(for: "A"), 0x00)        // case-insensitive (kVK_ANSI_A)
        XCTAssertEqual(KeyName.keyCode(for: "0"), 0x1D)        // kVK_ANSI_0
        XCTAssertEqual(KeyName.keyCode(for: "1"), 0x12)        // kVK_ANSI_1
        XCTAssertEqual(KeyName.keyCode(for: "9"), 0x19)        // kVK_ANSI_9
    }

    // MARK: unknown → nil → REFUSE (mirror testUnknownActionReturnsNil)

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(KeyName.keyCode(for: "frobnicate"))
        XCTAssertNil(KeyName.keyCode(for: ""))
        XCTAssertNil(KeyName.keyCode(for: "f13"))   // not in the exposed table
    }

    // MARK: KeyModifier.flag — token → flag

    func testModifierTokensMapToFlags() {
        XCTAssertEqual(KeyModifier.flag(for: "cmd"),     .maskCommand)
        XCTAssertEqual(KeyModifier.flag(for: "command"), .maskCommand)
        XCTAssertEqual(KeyModifier.flag(for: "shift"),   .maskShift)
        XCTAssertEqual(KeyModifier.flag(for: "alt"),     .maskAlternate)
        XCTAssertEqual(KeyModifier.flag(for: "option"),  .maskAlternate)
        XCTAssertEqual(KeyModifier.flag(for: "opt"),     .maskAlternate)
        XCTAssertEqual(KeyModifier.flag(for: "ctrl"),    .maskControl)
        XCTAssertEqual(KeyModifier.flag(for: "control"), .maskControl)
        XCTAssertEqual(KeyModifier.flag(for: "CMD"),     .maskCommand)   // case-insensitive
    }

    func testUnknownModifierReturnsNil() {
        XCTAssertNil(KeyModifier.flag(for: "hyper"))
        XCTAssertNil(KeyModifier.flag(for: ""))
        XCTAssertNil(KeyModifier.flag(for: "fn"))
    }

    // MARK: KeySpec.parse — chord parse (base = LAST token, flags OR'd)

    func testBareKeyParsesWithEmptyFlags() throws {
        let s = try KeySpec.parse("return")
        XCTAssertEqual(s.keyCode, KeyName.keyCode(for: "return"))
        XCTAssertTrue(s.flags.isEmpty)
    }

    func testSingleModifierChordParses() throws {
        let s = try KeySpec.parse("cmd+s")
        XCTAssertEqual(s.keyCode, KeyName.keyCode(for: "s"))
        XCTAssertTrue(s.flags.contains(.maskCommand))
        XCTAssertFalse(s.flags.contains(.maskShift))
    }

    func testMultiModifierChordOrsFlags() throws {
        let s = try KeySpec.parse("cmd+shift+t")
        XCTAssertEqual(s.keyCode, KeyName.keyCode(for: "t"))
        XCTAssertTrue(s.flags.contains(.maskCommand) && s.flags.contains(.maskShift))
    }

    func testCtrlLetterChordParses() throws {
        let s = try KeySpec.parse("ctrl+a")
        XCTAssertEqual(s.keyCode, KeyName.keyCode(for: "a"))
        XCTAssertTrue(s.flags.contains(.maskControl))
    }

    func testChordIsCaseInsensitiveAndNormalized() throws {
        let s = try KeySpec.parse("CMD+Shift+T")
        XCTAssertEqual(s.keyCode, KeyName.keyCode(for: "t"))
        XCTAssertTrue(s.flags.contains(.maskCommand) && s.flags.contains(.maskShift))
        XCTAssertEqual(s.name, "cmd+shift+t")   // normalized for the report
    }

    // MARK: bad spec REFUSES (throws) — mirror the XCTAssertNil refuse arms

    func testUnknownBaseKeyThrows() {
        XCTAssertThrowsError(try KeySpec.parse("cmd+frobnicate")) { error in
            guard case GhostHandsError.unknownKey = error else {
                return XCTFail("an unknown base key must throw .unknownKey")
            }
        }
    }

    func testUnknownModifierThrows() {
        XCTAssertThrowsError(try KeySpec.parse("badmod+s")) { error in
            guard case GhostHandsError.badKeySpec = error else {
                return XCTFail("an unknown modifier token must throw .badKeySpec")
            }
        }
    }

    func testEmptySpecThrows() {
        XCTAssertThrowsError(try KeySpec.parse("")) { error in
            guard case GhostHandsError.badKeySpec = error else {
                return XCTFail("an empty spec must throw .badKeySpec")
            }
        }
    }

    func testTrailingPlusWithNoBaseThrows() {
        // "cmd+" has a modifier but no base key → REFUSE (no key to post).
        XCTAssertThrowsError(try KeySpec.parse("cmd+")) { error in
            guard case GhostHandsError.badKeySpec = error else {
                return XCTFail("a spec with no base key must throw .badKeySpec")
            }
        }
    }

    // MARK: --visible flag parse REUSES PixelFlags (mirror testFlagParseVisibleToggles)

    func testKeyVisibleFlagParseReusesPixelFlags() {
        let (mode, pos) = PixelFlags.parse(["return", "Safari", "--visible"])
        XCTAssertEqual(mode, .visible)
        XCTAssertEqual(pos, ["return", "Safari"])
    }

    func testKeyDefaultModeIsInvisible() {
        let (mode, pos) = PixelFlags.parse(["cmd+s", "TextEdit"])
        XCTAssertEqual(mode, .invisible)
        XCTAssertEqual(pos, ["cmd+s", "TextEdit"])
    }

    func testKeySpecOnlyPositionalParses() {
        // No app spec — `key return` posts to the frontmost app.
        let (mode, pos) = PixelFlags.parse(["return"])
        XCTAssertEqual(mode, .invisible)
        XCTAssertEqual(pos, ["return"])
    }

    // MARK: KeyOutcome honesty invariant — ALWAYS dispatched-unverified

    func testKeyOutcomeIsAlwaysDispatchedUnverified() {
        let o = KeyOutcome(app: "Safari", spec: "return", keyName: "return",
                           mode: .invisible, dispatched: true)
        XCTAssertTrue(o.dispatched)
        XCTAssertFalse(o.verified)    // a key has no built-in observable
        XCTAssertFalse(o.observable)
    }

    func testKeyOutcomeVisibleModeIsStillUnverified() {
        // Even the visible HID path is dispatched-unverified — there is no
        // self-observable for a key in EITHER mode.
        let o = KeyOutcome(app: "Chrome", spec: "cmd+shift+t", keyName: "cmd+shift+t",
                           mode: .visible, dispatched: true)
        XCTAssertEqual(o.mode, .visible)
        XCTAssertFalse(o.verified)
        XCTAssertFalse(o.observable)
    }

    // MARK: KeyMode is an alias of PixelMode (the shared invisibility axis)

    func testKeyModeAliasesPixelMode() {
        let m: KeyMode = .invisible
        XCTAssertEqual(m, PixelMode.invisible)
        let v: KeyMode = .visible
        XCTAssertEqual(v, PixelMode.visible)
    }
}
