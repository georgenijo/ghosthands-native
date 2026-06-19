import Foundation

/// The PURE chord → CDP `Input.dispatchKeyEvent` field layer — the only surface
/// `web key`'s hermetic test touches. A chord string ("cmd+shift+l") maps to the
/// four fields Chromium needs to fire an app KEYBINDING/accelerator — `key`,
/// `code`, `windowsVirtualKeyCode`, and the CDP `modifiers` bitfield — by table
/// lookup + a split on '+', with NO socket and NO event posted. This mirrors
/// `KeySpec` (the macOS-CGEvent twin), but the codes are DIFFERENT: CDP wants DOM
/// `key`/`code` values + a Windows virtual-key code + its OWN modifier bitfield,
/// not the ANSI virtual keycodes `CGEvent` uses. The impure dispatch (open a page
/// session, send keyDown+keyUp) lives in `Web.swift`.
///
/// HONESTY: a keystroke has NO in-page observable (no read-back, no nav), so a
/// `web key` dispatch is ALWAYS reported dispatched-unverified — the parse REFUSES
/// (`badKeySpec` / `unknownKey`) rather than guess a key, but a dispatched chord is
/// never claimed to have "worked".

/// The CDP modifier bitfield, per the DevTools protocol
/// (`Input.dispatchKeyEvent.modifiers`): Alt=1, Ctrl=2, Meta(⌘)=4, Shift=8, OR'd.
/// A token → bit lookup; an unknown token returns nil so a chord with a bad
/// modifier REFUSES rather than silently drop it (mirrors `KeyModifier`).
public enum CDPModifier {
    public static let alt = 1
    public static let ctrl = 2
    public static let meta = 4
    public static let shift = 8

    public static func bit(for token: String) -> Int? {
        switch token.lowercased() {
        case "cmd", "command":       return meta
        case "shift":                return shift
        case "alt", "option", "opt": return alt
        case "ctrl", "control":      return ctrl
        default:                     return nil
        }
    }
}

/// The DOM `key`/`code`/`windowsVirtualKeyCode` triple for a base key, before any
/// shift-casing is applied. Pure value type.
public struct CDPKeyCode: Sendable, Equatable {
    /// The DOM `key` value ("l", "Enter", "ArrowDown"). Shift-uppercased for a
    /// letter by `CDPKeySpec.parse` when Shift is in the chord.
    public let key: String
    /// The DOM `code` ("KeyL", "Enter", "Digit5") — physical-key identity, never
    /// shift-cased.
    public let code: String
    /// The Windows virtual-key code Chromium matches accelerators on (L=76,
    /// Enter=13).
    public let windowsVirtualKeyCode: Int

    public init(key: String, code: String, windowsVirtualKeyCode: Int) {
        self.key = key
        self.code = code
        self.windowsVirtualKeyCode = windowsVirtualKeyCode
    }
}

/// (friendlyName) → CDP key triple. Pure and total; an unknown name returns nil so
/// the caller emits the usage-class `.unknownKey` REFUSE. Letters a–z and digits
/// 0–9 map to their DOM `code` + Windows VK; the common named keys cover what an
/// app keybinding needs.
public enum CDPKeyName {
    public static func code(for name: String) -> CDPKeyCode? {
        let n = name.lowercased()
        // Single letter a–z.
        if n.count == 1, let ch = n.first, ch.isLetter, ch.isASCII {
            let upper = Character(ch.uppercased())
            let vk = Int(upper.asciiValue ?? 65)        // 'A'=65 … 'Z'=90
            return CDPKeyCode(key: n, code: "Key\(upper)", windowsVirtualKeyCode: vk)
        }
        // Single digit 0–9 (top number row — DOM `Digit*`, NOT the keypad).
        if n.count == 1, let ch = n.first, ch.isNumber, ch.isASCII {
            let vk = Int(ch.asciiValue ?? 48)           // '0'=48 … '9'=57
            return CDPKeyCode(key: n, code: "Digit\(n)", windowsVirtualKeyCode: vk)
        }
        switch n {
        case "return", "enter":     return CDPKeyCode(key: "Enter", code: "Enter", windowsVirtualKeyCode: 13)
        case "tab":                 return CDPKeyCode(key: "Tab", code: "Tab", windowsVirtualKeyCode: 9)
        case "escape", "esc":       return CDPKeyCode(key: "Escape", code: "Escape", windowsVirtualKeyCode: 27)
        case "space", "spacebar":   return CDPKeyCode(key: " ", code: "Space", windowsVirtualKeyCode: 32)
        case "delete", "backspace": return CDPKeyCode(key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8)
        case "up":                  return CDPKeyCode(key: "ArrowUp", code: "ArrowUp", windowsVirtualKeyCode: 38)
        case "down":                return CDPKeyCode(key: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40)
        case "left":                return CDPKeyCode(key: "ArrowLeft", code: "ArrowLeft", windowsVirtualKeyCode: 37)
        case "right":               return CDPKeyCode(key: "ArrowRight", code: "ArrowRight", windowsVirtualKeyCode: 39)
        default:                    return nil
        }
    }

    public static let known =
        "return|enter|tab|escape|space|delete|up|down|left|right|<letter a-z>|<digit 0-9>"
}

/// A parsed chord ready for `Input.dispatchKeyEvent`: the DOM `key`/`code`, the
/// Windows VK, and the OR'd CDP modifier bitfield. Plain value type — no socket,
/// no pid — so the whole parse is unit-testable on fabricated strings with ZERO
/// event dispatched (exactly like `KeySpec`).
public struct CDPKeySpec: Sendable, Equatable {
    /// The DOM `key` value, shift-uppercased for a letter when Shift is held.
    public let key: String
    /// The DOM `code` (physical key identity).
    public let code: String
    /// The Windows virtual-key code.
    public let windowsVirtualKeyCode: Int
    /// The OR'd CDP modifier bitfield (Alt=1|Ctrl=2|Meta=4|Shift=8), 0 for a bare key.
    public let modifiers: Int
    /// The normalized chord string ("cmd+shift+l") for the honest report.
    public let name: String

    public init(key: String, code: String, windowsVirtualKeyCode: Int,
                modifiers: Int, name: String) {
        self.key = key
        self.code = code
        self.windowsVirtualKeyCode = windowsVirtualKeyCode
        self.modifiers = modifiers
        self.name = name
    }

    /// Parse a chord like "return", "cmd+l", "cmd+shift+l", "ctrl+a": split on '+',
    /// the LAST token is the base key, all earlier tokens are CDP modifier bits OR'd
    /// into one mask. When Shift is in the chord and the base is a LETTER, the DOM
    /// `key` is uppercased (matching what a real Shift+letter produces); `code` and
    /// the VK never change.
    ///
    /// REFUSES (throws) rather than guess (mirrors `KeySpec.parse`):
    /// - empty spec / no base token → `.badKeySpec`
    /// - an unknown modifier token  → `.badKeySpec` (don't drop a modifier silently)
    /// - an unknown base key        → `.unknownKey`
    public static func parse(_ spec: String) throws -> CDPKeySpec {
        let components = spec.split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        guard let base = components.last, !base.isEmpty, !components.isEmpty else {
            throw GhostHandsError.badKeySpec(spec)
        }
        guard let triple = CDPKeyName.code(for: base) else {
            throw GhostHandsError.unknownKey(base)
        }
        var modifiers = 0
        for token in components.dropLast() {
            guard let bit = CDPModifier.bit(for: token) else {
                throw GhostHandsError.badKeySpec(spec)
            }
            modifiers |= bit
        }
        // Shift+letter produces the uppercase DOM `key`; everything else as-is.
        let shifted = (modifiers & CDPModifier.shift) != 0
        let key = (shifted && base.count == 1 && base.first?.isLetter == true)
            ? triple.key.uppercased()
            : triple.key
        return CDPKeySpec(key: key, code: triple.code,
                          windowsVirtualKeyCode: triple.windowsVirtualKeyCode,
                          modifiers: modifiers, name: spec.lowercased())
    }
}
