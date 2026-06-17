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
            print(report(outcome, name: name))
        } catch let error as GhostHandsError {
            FileHandle.standardError.write(Data("click failed: \(error)\n".utf8))
            exit(1)
        } catch {
            // No other throw site today, but never leak a raw reflection.
            FileHandle.standardError.write(Data("click failed: unexpected error\n".utf8))
            exit(1)
        }
    }

    /// Honest one-liner: distinguishes a VERIFIED effect (observed change) from
    /// a mere DISPATCH (AX accepted, effect not observable from the element).
    static func report(_ o: ClickOutcome, name: String) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            return "clicked \(name.debugDescription) \(where_) — verified: \(o.evidence ?? "changed")"
        }
        return "pressed \(name.debugDescription) \(where_) — AXPress accepted; "
            + "no observable change (effect unverified)"
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
