import Foundation
import GhostHandsKit

/// The no-model act tier: `ghosthands click "<name>" <app>`.
///
/// Honest by construction — it prints success only when the AX layer accepted
/// the action, and reports the element's value read back as evidence. A miss
/// (name not on screen, action rejected, no permission) is a clean one-line
/// stderr + non-zero exit, never a traceback and never a fabricated "done".
@main
struct GhostHandsCLI {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first else { usage() }

        switch verb {
        case "version", "--version", "-v":
            print("ghosthands \(GhostHands.version)")
        case "click":
            runClick(Array(args.dropFirst()))
        default:
            usage()
        }
    }

    @MainActor
    static func runClick(_ rest: [String]) {
        guard rest.count >= 2 else { usage() }
        let name = rest[0]
        let appSpec = rest[1]
        do {
            let outcome = try GhostHands.click(name: name, appSpec: appSpec)
            print("clicked \(name.debugDescription) (role=\(outcome.role)) "
                + "in \(outcome.app) — AX accepted\(deltaText(outcome))")
        } catch {
            FileHandle.standardError.write(Data("click failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// World-evidence suffix: what the element's value did across the action.
    static func deltaText(_ o: ClickOutcome) -> String {
        if o.valueChanged {
            return " — value \(o.valueBefore ?? "nil") → \(o.valueAfter ?? "nil")"
        }
        if let after = o.valueAfter, !after.isEmpty {
            return " — value \(after) (unchanged)"
        }
        return ""
    }

    static func usage() -> Never {
        let text = """
        ghosthands \(GhostHands.version) — honesty-first macOS computer-use core

        USAGE:
          ghosthands click "<name>" <app>   press a named element (AX, cursor-less)
          ghosthands version

        <app> = bundle id, pid, or (partial) app name. Example:
          ghosthands click "New Folder" Finder
        """
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }
}
