import Foundation

// The PURE arg parse for the `see` verb. Lives in the kit (like `PixelFlags` /
// `WindowSelector`) so the flag/threading honesty — `--in <css>` (scope the CDP
// eye), `--target <n|title>` (pick the renderer), `--debug-port N`, `--no-ocr`,
// and the app positional — is unit-testable with NO CLI run and NO live app.
//
// HONESTY the parse pins down (so a fused-eye read can't silently lose intent):
//   - `--in` and `--target` COMPOSE: both are extracted independently, in any
//     order, so `see <app> --in <css> --target <n>` yields BOTH a scope and a
//     pick — the leaf then reads the scope off the picked renderer.
//   - A present-but-VALUELESS `--in` or `--target` REFUSES (`.missingValue`)
//     rather than silently dropping the flag (which would read the whole page /
//     the default renderer after the user explicitly tried to scope/pick).
//   - A missing app positional REFUSES (`.missingApp`).
// The leaf (`GhostHands.see`) still owns the WORLD honesty (a `--target` that
// matches no renderer refuses at the CDP layer); this struct only owns the parse.

public enum SeeArgs {
    /// The parsed, validated `see` invocation — ready to thread into
    /// `GhostHands.see`. `pick` is nil when no `--target` was given (read the
    /// default renderer); `scope` is nil when no `--in` was given (whole-page CDP
    /// eye); `runOCR` defaults true (`--no-ocr` turns it off).
    public struct Parsed: Sendable, Equatable {
        public let appSpec: String
        public let debugPort: Int?
        public let pick: CDPTargetPick.Selector?
        public let scope: String?
        public let runOCR: Bool

        public init(appSpec: String, debugPort: Int?, pick: CDPTargetPick.Selector?,
                    scope: String?, runOCR: Bool) {
            self.appSpec = appSpec
            self.debugPort = debugPort
            self.pick = pick
            self.scope = scope
            self.runOCR = runOCR
        }
    }

    /// A parse REFUSE — the CLI maps each to a clean one-line stderr + exit ≠ 0.
    public enum Refusal: Sendable, Equatable {
        /// A flag was present with no following value (`--in`/`--target` dangling).
        case missingValue(flag: String)
        /// No app positional remained after the flags were consumed.
        case missingApp
    }

    public enum Result: Sendable, Equatable {
        case ok(Parsed)
        case refuse(Refusal)
    }

    /// Pull a `<flag> <value>` pair out of `args` (in any order), returning the
    /// value (nil if the flag is absent), whether the flag token appeared AT ALL
    /// (so a dangling, valueless flag is distinguishable from an absent one), and
    /// the remaining args with that pair removed. Mirrors the CLI's
    /// `extractFlagValue` so the value isn't mistaken for a later positional.
    static func extract(_ flag: String, from args: [String])
        -> (value: String?, present: Bool, rest: [String]) {
        var value: String?
        var present = false
        var rest: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == flag {
                present = true
                if i + 1 < args.count { value = args[i + 1]; i += 2 } else { i += 1 }
            } else {
                rest.append(args[i]); i += 1
            }
        }
        return (value, present, rest)
    }

    /// Parse the already-`scanJSON`'d `see` args. ORDER matters for honesty:
    /// `--in` is pulled FIRST so its CSS value can't be mistaken for the `--target`
    /// value or the app positional; `--target` next, then `--debug-port`; the first
    /// leftover positional is the app. `--no-ocr` is a bare boolean (any position).
    public static func parse(_ args: [String]) -> Result {
        var rest = args
        let hadNoOCR = rest.contains("--no-ocr")
        rest.removeAll { $0 == "--no-ocr" }

        let (scopeRaw, scopePresent, afterScope) = extract("--in", from: rest)
        if scopePresent, scopeRaw == nil { return .refuse(.missingValue(flag: "--in")) }

        let (targetRaw, targetPresent, afterTarget) = extract("--target", from: afterScope)
        if targetPresent, targetRaw == nil { return .refuse(.missingValue(flag: "--target")) }
        let pick = targetRaw.map { CDPTargetPick.parse($0) }

        let (portRaw, _, afterPort) = extract("--debug-port", from: afterTarget)
        let debugPort = portRaw.flatMap { Int($0) }

        guard let appSpec = afterPort.first else { return .refuse(.missingApp) }

        return .ok(Parsed(appSpec: appSpec, debugPort: debugPort, pick: pick,
                          scope: scopeRaw, runOCR: !hadNoOCR))
    }
}
