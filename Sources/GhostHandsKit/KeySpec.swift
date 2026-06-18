import CoreGraphics
import Foundation

/// The PURE key-spec layer — the ONLY surface the hermetic test touches. No
/// CGEvent, no pid, no live app: a key name maps to a virtual keycode and a
/// modifier token maps to a `CGEventFlags` bit by table lookup alone, and a
/// chord parses by splitting on '+'. `CGKeyCode` is a `UInt16` and `CGEventFlags`
/// is an `OptionSet`, so the WHOLE name→code + token→flag + chord-combine path
/// constructs and compares with NO key ever posted — exactly like `ActionName`
/// and `ValueCoercion`. The impure CGEvent build + post lives in `Key.swift`.

/// (friendlyName) → ANSI virtual keycode. Pure and total, modeled 1:1 on
/// `ActionName.axAction(for:)`: an unknown name returns nil so the caller emits
/// the usage-class `.unknownKey` REFUSE rather than posting a guessed key.
public enum KeyName {
    /// Map a key name to its ANSI virtual keycode (`CGKeyCode`). Case-insensitive
    /// like `ActionName`. `enter` ALIASES `return`; `esc`/`backspace`/`spacebar`
    /// are accepted aliases. Single letters a–z and digits 0–9 map to their ANSI
    /// codes. Unknown → nil (caller throws `.unknownKey`).
    public static func keyCode(for name: String) -> CGKeyCode? {
        switch name.lowercased() {
        // Named keys (ANSI virtual keycodes).
        case "return", "enter":      return 0x24   // 36 — enter ALIASES return
        case "tab":                  return 0x30   // 48
        case "space", "spacebar":    return 0x31   // 49
        case "escape", "esc":        return 0x35   // 53
        case "delete", "backspace":  return 0x33   // 51
        case "up":                   return 0x7E   // 126
        case "down":                 return 0x7D   // 125
        case "left":                 return 0x7B   // 123
        case "right":                return 0x7C   // 124

        // Letters a–z (ANSI keycode table — NOT alphabetical order).
        case "a": return 0x00
        case "b": return 0x0B
        case "c": return 0x08
        case "d": return 0x02
        case "e": return 0x0E
        case "f": return 0x03
        case "g": return 0x05
        case "h": return 0x04
        case "i": return 0x22
        case "j": return 0x26
        case "k": return 0x28
        case "l": return 0x25
        case "m": return 0x2E
        case "n": return 0x2D
        case "o": return 0x1F
        case "p": return 0x23
        case "q": return 0x0C
        case "r": return 0x0F
        case "s": return 0x01
        case "t": return 0x11
        case "u": return 0x20
        case "v": return 0x09
        case "w": return 0x0D
        case "x": return 0x07
        case "y": return 0x10
        case "z": return 0x06

        // Digits 0–9 (ANSI keycode table — the top number row, not the keypad).
        case "0": return 0x1D
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19

        default: return nil   // unknown → caller throws .unknownKey
        }
    }

    /// The canonical usage string of accepted base keys (for the REFUSE message).
    public static let known =
        "return|enter|tab|escape|space|delete|up|down|left|right|<letter a-z>|<digit 0-9>"
}

/// (modifierToken) → `CGEventFlags` bit. Pure and total; an unknown token returns
/// nil so a chord with a bad modifier REFUSES via `.badKeySpec` rather than
/// silently dropping the modifier.
public enum KeyModifier {
    public static func flag(for token: String) -> CGEventFlags? {
        switch token.lowercased() {
        case "cmd", "command":      return .maskCommand
        case "shift":               return .maskShift
        case "alt", "option", "opt": return .maskAlternate
        case "ctrl", "control":     return .maskControl
        default:                    return nil
        }
    }
}

/// A parsed keystroke/chord: the base virtual keycode + the OR'd modifier flags +
/// the canonical name (for the report). Plain value type — no CGEvent, no pid —
/// so the whole parse is unit-testable on fabricated strings with ZERO key posted.
public struct KeySpec: Sendable, Equatable {
    /// The base key's ANSI virtual keycode.
    public let keyCode: CGKeyCode
    /// The combined modifier mask (`.maskCommand | .maskShift | …`), empty for a
    /// bare key.
    public let flags: CGEventFlags
    /// The normalized spec string ("cmd+shift+t") for the honest report.
    public let name: String

    public init(keyCode: CGKeyCode, flags: CGEventFlags, name: String) {
        self.keyCode = keyCode
        self.flags = flags
        self.name = name
    }

    /// Parse a spec like "return", "cmd+s", "cmd+shift+t", "ctrl+a": split on '+',
    /// the LAST token is the base key, all earlier tokens are modifiers OR'd into
    /// one mask.
    ///
    /// REFUSES (throws) rather than guess:
    /// - empty spec / no base token → `.badKeySpec`
    /// - an unknown modifier token  → `.badKeySpec` (don't drop a modifier silently)
    /// - an unknown base key        → `.unknownKey`
    ///
    /// This is the entire testable surface; the CGEvent build lives in `Key.swift`.
    public static func parse(_ spec: String) throws -> KeySpec {
        let components = spec.split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        // An empty spec, or a spec that splits to an empty base token ("cmd+"),
        // has no base key — REFUSE rather than post nothing / guess.
        guard let base = components.last, !base.isEmpty, !components.isEmpty else {
            throw GhostHandsError.badKeySpec(spec)
        }

        guard let keyCode = KeyName.keyCode(for: base) else {
            throw GhostHandsError.unknownKey(base)
        }

        var flags: CGEventFlags = []
        for token in components.dropLast() {
            guard let f = KeyModifier.flag(for: token) else {
                throw GhostHandsError.badKeySpec(spec)
            }
            flags.insert(f)
        }

        return KeySpec(keyCode: keyCode, flags: flags, name: spec.lowercased())
    }
}

/// `key`'s delivery mode is the SAME invisibility axis as the pixel tier, so we
/// REUSE `PixelMode` directly rather than introduce a parallel enum:
/// `.invisible` = `CGEventPostToPid` (cursor-less, no focus steal, background
/// best-effort); `.visible` = activate the app + post through `.cghidEventTap`.
public typealias KeyMode = PixelMode

/// The honest outcome of a `key` dispatch. Mirrors `PixelOutcome`, but a key
/// event has NO built-in observable (no AX read-back, no caller-supplied point to
/// screenshot-diff), so `verified` is ALWAYS false by default — `key` is
/// dispatched-unverified in BOTH modes, analogous to `window raise`. Only an
/// OPTIONAL focused-field witness (out of scope) could ever upgrade it.
public struct KeyOutcome: Sendable, Equatable {
    /// The resolved app name (or "frontmost" when no app spec was given), for the
    /// report.
    public let app: String
    /// The spec that was posted ("cmd+shift+t"), for the report.
    public let spec: String
    /// The base key's canonical name (for the report).
    public let keyName: String
    /// The delivery mode used; `.visible` is surfaced so a focus steal is LABELLED.
    public let mode: KeyMode
    /// True — we posted the event pair.
    public let dispatched: Bool
    /// ALWAYS false unless an external effect-witness is wired (out of scope): a
    /// key has no self-observable.
    public let verified: Bool
    /// ALWAYS false: there is no built-in observable for a key event.
    public let observable: Bool

    public init(app: String, spec: String, keyName: String, mode: KeyMode = .invisible,
                dispatched: Bool, verified: Bool = false, observable: Bool = false) {
        self.app = app
        self.spec = spec
        self.keyName = keyName
        self.mode = mode
        self.dispatched = dispatched
        self.verified = verified
        self.observable = observable
    }
}
