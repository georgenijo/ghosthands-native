import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE chord → CDP key-field layer (`CDPKeySpec`) and the PURE
/// `--target` page chooser (`CDPTargetPick`), on FABRICATED strings / target lists.
/// NEVER opens a socket or drives a live browser (the env rule): every input is a
/// hand-built spec / `CDPTarget`. Mirrors `KeySpecTests` (the CGEvent twin) and the
/// CDP decode tests.
final class CDPKeySpecTests: XCTestCase {

    // MARK: CDPModifier — token → CDP bitfield (Alt=1|Ctrl=2|Meta=4|Shift=8)

    // PINNED to the DevTools protocol constants (an INDEPENDENT cross-check, not
    // circular against the lookup under test).
    func testModifierBits() {
        XCTAssertEqual(CDPModifier.bit(for: "cmd"), 4)      // Meta
        XCTAssertEqual(CDPModifier.bit(for: "command"), 4)
        XCTAssertEqual(CDPModifier.bit(for: "shift"), 8)    // Shift
        XCTAssertEqual(CDPModifier.bit(for: "alt"), 1)      // Alt
        XCTAssertEqual(CDPModifier.bit(for: "option"), 1)
        XCTAssertEqual(CDPModifier.bit(for: "opt"), 1)
        XCTAssertEqual(CDPModifier.bit(for: "ctrl"), 2)     // Control
        XCTAssertEqual(CDPModifier.bit(for: "control"), 2)
    }

    func testModifierBitsCaseInsensitive() {
        XCTAssertEqual(CDPModifier.bit(for: "CMD"), 4)
        XCTAssertEqual(CDPModifier.bit(for: "Shift"), 8)
    }

    func testUnknownModifierIsNil() {
        XCTAssertNil(CDPModifier.bit(for: "hyper"))
        XCTAssertNil(CDPModifier.bit(for: "fn"))
        XCTAssertNil(CDPModifier.bit(for: ""))
    }

    // MARK: CDPKeyName — base key → DOM key/code + Windows VK

    func testLetterKeyTriple() {
        let l = CDPKeyName.code(for: "l")
        XCTAssertEqual(l?.key, "l")
        XCTAssertEqual(l?.code, "KeyL")
        XCTAssertEqual(l?.windowsVirtualKeyCode, 76)        // ASCII 'L'
        let a = CDPKeyName.code(for: "A")                   // case-insensitive
        XCTAssertEqual(a?.key, "a")
        XCTAssertEqual(a?.code, "KeyA")
        XCTAssertEqual(a?.windowsVirtualKeyCode, 65)        // ASCII 'A'
    }

    func testDigitKeyTriple() {
        let five = CDPKeyName.code(for: "5")
        XCTAssertEqual(five?.key, "5")
        XCTAssertEqual(five?.code, "Digit5")
        XCTAssertEqual(five?.windowsVirtualKeyCode, 53)     // ASCII '5'
        XCTAssertEqual(CDPKeyName.code(for: "0")?.windowsVirtualKeyCode, 48)
    }

    func testNamedKeyTriples() {
        // PINNED to the standard Windows VK codes Chromium matches on.
        XCTAssertEqual(CDPKeyName.code(for: "return")?.windowsVirtualKeyCode, 13)
        XCTAssertEqual(CDPKeyName.code(for: "enter")?.code, "Enter")
        XCTAssertEqual(CDPKeyName.code(for: "tab")?.windowsVirtualKeyCode, 9)
        XCTAssertEqual(CDPKeyName.code(for: "escape")?.windowsVirtualKeyCode, 27)
        XCTAssertEqual(CDPKeyName.code(for: "esc")?.code, "Escape")
        XCTAssertEqual(CDPKeyName.code(for: "space")?.key, " ")
        XCTAssertEqual(CDPKeyName.code(for: "space")?.code, "Space")
        XCTAssertEqual(CDPKeyName.code(for: "backspace")?.windowsVirtualKeyCode, 8)
        XCTAssertEqual(CDPKeyName.code(for: "up")?.code, "ArrowUp")
        XCTAssertEqual(CDPKeyName.code(for: "down")?.windowsVirtualKeyCode, 40)
        XCTAssertEqual(CDPKeyName.code(for: "left")?.windowsVirtualKeyCode, 37)
        XCTAssertEqual(CDPKeyName.code(for: "right")?.code, "ArrowRight")
    }

    func testUnknownBaseKeyIsNil() {
        XCTAssertNil(CDPKeyName.code(for: "frobnicate"))
        XCTAssertNil(CDPKeyName.code(for: "f5"))            // function keys unmapped
        XCTAssertNil(CDPKeyName.code(for: ""))
    }

    // MARK: CDPKeySpec.parse — the chord → fields path (the capstone's ⇧⌘L)

    func testParseChordWithShiftUppercasesLetterKey() throws {
        // Cursor's ⇧⌘L agent panel — the capstone chord.
        let s = try CDPKeySpec.parse("cmd+shift+l")
        XCTAssertEqual(s.key, "L")                          // shift → uppercase DOM key
        XCTAssertEqual(s.code, "KeyL")                      // code is never shift-cased
        XCTAssertEqual(s.windowsVirtualKeyCode, 76)
        XCTAssertEqual(s.modifiers, 12)                     // Meta(4) | Shift(8)
        XCTAssertEqual(s.name, "cmd+shift+l")
    }

    func testParseChordWithoutShiftKeepsLowercase() throws {
        let s = try CDPKeySpec.parse("cmd+l")
        XCTAssertEqual(s.key, "l")
        XCTAssertEqual(s.code, "KeyL")
        XCTAssertEqual(s.modifiers, 4)                      // Meta only
    }

    func testParseBareNamedKey() throws {
        let s = try CDPKeySpec.parse("return")
        XCTAssertEqual(s.key, "Enter")
        XCTAssertEqual(s.code, "Enter")
        XCTAssertEqual(s.windowsVirtualKeyCode, 13)
        XCTAssertEqual(s.modifiers, 0)
    }

    func testParseShiftDigitDoesNotUppercase() throws {
        // A digit base has no uppercase form — shift only sets the bit.
        let s = try CDPKeySpec.parse("ctrl+shift+5")
        XCTAssertEqual(s.key, "5")
        XCTAssertEqual(s.code, "Digit5")
        XCTAssertEqual(s.modifiers, 10)                     // Ctrl(2) | Shift(8)
    }

    func testParseMultiModifierOrdering() throws {
        // Modifiers OR regardless of order.
        let s = try CDPKeySpec.parse("shift+alt+cmd+a")
        XCTAssertEqual(s.key, "A")
        XCTAssertEqual(s.modifiers, 4 | 8 | 1)              // Meta|Shift|Alt = 13
    }

    func testParseRefusesEmptyAndDanglingPlus() {
        XCTAssertThrowsError(try CDPKeySpec.parse("")) { e in
            guard case GhostHandsError.badKeySpec = e else { return XCTFail("want badKeySpec") }
        }
        XCTAssertThrowsError(try CDPKeySpec.parse("cmd+")) { e in
            guard case GhostHandsError.badKeySpec = e else { return XCTFail("want badKeySpec") }
        }
    }

    func testParseRefusesUnknownModifier() {
        XCTAssertThrowsError(try CDPKeySpec.parse("hyper+l")) { e in
            guard case GhostHandsError.badKeySpec = e else { return XCTFail("want badKeySpec") }
        }
    }

    func testParseRefusesUnknownBaseKey() {
        XCTAssertThrowsError(try CDPKeySpec.parse("cmd+frobnicate")) { e in
            guard case let GhostHandsError.unknownKey(k) = e else {
                return XCTFail("want unknownKey")
            }
            XCTAssertEqual(k, "frobnicate")
        }
    }

    // MARK: CDPTargetPick.parse — --target arg → index | substring

    func testTargetPickParse() {
        XCTAssertEqual(CDPTargetPick.parse("2"), .index(2))
        XCTAssertEqual(CDPTargetPick.parse(" 3 "), .index(3))     // trims
        XCTAssertEqual(CDPTargetPick.parse("0"), .match("0"))     // 0 is not a 1-based index
        XCTAssertEqual(CDPTargetPick.parse("Cursor"), .match("Cursor"))
        XCTAssertEqual(CDPTargetPick.parse("github.com"), .match("github.com"))
    }

    // MARK: CDPTargetPick.choose — pick a page from /json/list

    private func t(_ id: String, title: String, url: String, ws: String) -> CDPTarget {
        CDPTarget(id: id, url: url, title: title, type: "page", webSocketDebuggerUrl: ws)
    }

    /// A list where the 2nd entry is NOT debuggable (empty ws url) — it must be
    /// skipped so indices count debuggable pages only.
    private func sampleTargets() -> [CDPTarget] {
        [
            t("a", title: "Welcome", url: "vscode://welcome", ws: "ws://127.0.0.1:9333/a"),
            t("b", title: "DevTools", url: "devtools://x", ws: ""),                 // not debuggable
            t("c", title: "Project — Cursor", url: "file:///proj", ws: "ws://127.0.0.1:9333/c"),
        ]
    }

    func testChooseDefaultIsFirstDebuggablePage() {
        let c = CDPTargetPick.choose(sampleTargets(), nil)
        XCTAssertEqual(c?.target.id, "a")
        XCTAssertEqual(c?.index, 1)
        XCTAssertEqual(c?.matchCount, 2)                          // 2 debuggable pages
    }

    func testChooseIndexSkipsNonDebuggable() {
        // index 2 is the 2nd DEBUGGABLE page (id "c"), not the empty-ws "b".
        let c = CDPTargetPick.choose(sampleTargets(), .index(2))
        XCTAssertEqual(c?.target.id, "c")
        XCTAssertEqual(c?.index, 2)
    }

    func testChooseIndexOutOfRangeIsNil() {
        XCTAssertNil(CDPTargetPick.choose(sampleTargets(), .index(3)))  // only 2 debuggable
        XCTAssertNil(CDPTargetPick.choose(sampleTargets(), .index(0)))
    }

    func testChooseMatchByTitleCaseInsensitive() {
        let c = CDPTargetPick.choose(sampleTargets(), .match("cursor"))
        XCTAssertEqual(c?.target.id, "c")
        XCTAssertEqual(c?.matchCount, 1)
    }

    func testChooseMatchByUrl() {
        let c = CDPTargetPick.choose(sampleTargets(), .match("welcome"))
        XCTAssertEqual(c?.target.id, "a")
    }

    func testChooseMatchNoHitIsNil() {
        XCTAssertNil(CDPTargetPick.choose(sampleTargets(), .match("nonsuch")))
    }

    func testChooseByExactId() {
        // The id arm pins act's reattach to the EXACT renderer see read (F1).
        let c = CDPTargetPick.choose(sampleTargets(), .id("c"))
        XCTAssertEqual(c?.target.id, "c")
        XCTAssertEqual(c?.matchCount, 1)
        // A non-debuggable id ("b" has empty ws) or an absent id → nil (caller refuses).
        XCTAssertNil(CDPTargetPick.choose(sampleTargets(), .id("b")))
        XCTAssertNil(CDPTargetPick.choose(sampleTargets(), .id("nonsuch")))
    }

    func testChooseEmptyPagesIsNil() {
        // A list with NO debuggable page → nil regardless of selector.
        let none = [t("x", title: "DevTools", url: "devtools://x", ws: "")]
        XCTAssertNil(CDPTargetPick.choose(none, nil))
        XCTAssertNil(CDPTargetPick.choose([], nil))
    }

    func testLabelFallback() {
        XCTAssertEqual(CDPTargetPick.label(t("a", title: "Hi", url: "u", ws: "w")), "Hi")
        XCTAssertEqual(CDPTargetPick.label(t("a", title: "", url: "http://u", ws: "w")), "http://u")
        XCTAssertEqual(CDPTargetPick.label(t("a", title: "", url: "", ws: "w")), "(untitled page)")
    }
}
