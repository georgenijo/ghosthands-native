import Foundation
import GhostHandsKit

/// The no-model GhostHands CLI — honest by construction.
///
/// Act tier:  `ghosthands click "<name>" <app>`  — press a named control (AX).
/// Read tier: `ghosthands snapshot <app> [--ax|--json]`  — dump the AX tree.
///            `ghosthands find "<name>" <app>`           — does it exist? (0/1).
///            `ghosthands shot <app> <out.png>`          — honest screenshot.
///
/// Every verb prints success ONLY on observed evidence and a miss is a clean
/// one-line stderr + non-zero exit — never a traceback, never a fabricated
/// "done", never a written-out black PNG.
@main
struct GhostHandsCLI {
    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first else { usage() }

        switch verb {
        case "version", "--version", "-v":
            print("ghosthands \(GhostHands.version)")
        case "click":
            runClick(Array(args.dropFirst()))
        case "snapshot":
            runSnapshot(Array(args.dropFirst()))
        case "find":
            runFind(Array(args.dropFirst()))
        case "shot":
            await runShot(Array(args.dropFirst()))
        default:
            usage()
        }
    }

    // MARK: - click

    @MainActor
    static func runClick(_ rest: [String]) {
        guard rest.count >= 2 else { usage() }
        let name = rest[0]
        let appSpec = rest[1]
        do {
            let outcome = try GhostHands.click(name: name, appSpec: appSpec)
            print(report(outcome, name: name))
        } catch let error as GhostHandsError {
            fail("click", error)
        } catch {
            failUnexpected("click")
        }
    }

    /// Honest one-liner: distinguishes a VERIFIED effect (observed change —
    /// possibly proven by a named sibling witness) from a mere DISPATCH.
    static func report(_ o: ClickOutcome, name: String) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            return "clicked \(name.debugDescription) \(where_) — verified: \(o.evidence ?? "changed")"
        }
        return "pressed \(name.debugDescription) \(where_) — AXPress accepted; "
            + "no observable change (effect unverified)"
    }

    // MARK: - snapshot

    @MainActor
    static func runSnapshot(_ rest: [String]) {
        // Accept: snapshot <app> [--ax|--json] in any order for the flag.
        var appSpec: String?
        var json = false
        for arg in rest {
            switch arg {
            case "--json": json = true
            case "--ax": json = false
            default: if appSpec == nil { appSpec = arg }
            }
        }
        guard let appSpec else { usage() }
        do {
            let result = try GhostHands.snapshot(appSpec: appSpec)
            if json {
                print(SnapshotRender.json(result.forest))
            } else {
                let tree = SnapshotRender.ax(result.forest)
                if !tree.isEmpty { print(tree) }
                FileHandle.standardError.write(
                    Data("— \(result.count) elements in \(result.app)\n".utf8))
            }
        } catch let error as GhostHandsError {
            fail("snapshot", error)
        } catch {
            failUnexpected("snapshot")
        }
    }

    // MARK: - find

    @MainActor
    static func runFind(_ rest: [String]) {
        guard rest.count >= 2 else { usage() }
        let query = rest[0]
        let appSpec = rest[1]
        do {
            let outcome = try GhostHands.find(query: query, appSpec: appSpec)
            if outcome.found, let line = FindResult.report(outcome.hits) {
                print(line)
                // exit 0 (default)
            } else {
                FileHandle.standardError.write(
                    Data("not found: \(query.debugDescription) in \(outcome.app)\n".utf8))
                exit(1)
            }
        } catch let error as GhostHandsError {
            fail("find", error)
        } catch {
            failUnexpected("find")
        }
    }

    // MARK: - shot

    @MainActor
    static func runShot(_ rest: [String]) async {
        guard rest.count >= 2 else { usage() }
        let appSpec = rest[0]
        let outPath = rest[1]
        do {
            let outcome = try await GhostHands.shot(appSpec: appSpec, outPath: outPath)
            print("wrote \(outcome.path) (\(outcome.width)×\(outcome.height))")
        } catch let error as GhostHandsError {
            fail("shot", error)
        } catch {
            failUnexpected("shot")
        }
    }

    // MARK: - failure helpers

    static func fail(_ verb: String, _ error: GhostHandsError) -> Never {
        FileHandle.standardError.write(Data("\(verb) failed: \(error)\n".utf8))
        exit(1)
    }

    static func failUnexpected(_ verb: String) -> Never {
        FileHandle.standardError.write(Data("\(verb) failed: unexpected error\n".utf8))
        exit(1)
    }

    static func usage() -> Never {
        let text = """
        ghosthands \(GhostHands.version) — honesty-first macOS computer-use core

        USAGE:
          ghosthands click "<name>" <app>          press a named control (AX, cursor-less)
          ghosthands snapshot <app> [--ax|--json]  dump the AX tree (pure read, default --ax)
          ghosthands find "<name>" <app>           does a named element exist? (exit 0/1)
          ghosthands shot <app> <out.png>          honest screenshot (refuses without Screen Recording)
          ghosthands version

        <app> = bundle id, pid, or (partial) app name. Examples:
          ghosthands click "New Folder" Finder
          ghosthands snapshot Calculator --json
          ghosthands find "7" Calculator
          ghosthands shot Calculator /tmp/calc.png

        Honesty: every verb reports observed evidence only. A click is VERIFIED only
        when a value change is observed (incl. a named sibling witness, e.g.
        'display 0 → 789'); otherwise it is honestly reported as dispatched-unverified.
        shot writes a file ONLY for real captured pixels — it refuses (no file) when
        Screen Recording is not granted, never a black PNG.
        """
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }
}
