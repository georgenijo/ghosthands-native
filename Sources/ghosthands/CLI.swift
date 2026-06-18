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
        case "type":
            runType(Array(args.dropFirst()))
        case "set-value":
            runSetValue(Array(args.dropFirst()))
        case "doubleclick":
            runDoubleClick(Array(args.dropFirst()))
        case "act":
            runAct(Array(args.dropFirst()))
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

    // MARK: - type

    @MainActor
    static func runType(_ rest: [String]) {
        guard rest.count >= 3 else { usage() }
        let text = rest[0]
        let field = rest[1]
        let appSpec = rest[2]
        do {
            let outcome = try GhostHands.type(text: text, field: field, appSpec: appSpec)
            print(reportValue(outcome))
        } catch let error as GhostHandsError {
            fail("type", error)
        } catch {
            failUnexpected("type")
        }
    }

    // MARK: - set-value

    @MainActor
    static func runSetValue(_ rest: [String]) {
        guard rest.count >= 3 else { usage() }
        let value = rest[0]
        let control = rest[1]
        let appSpec = rest[2]
        do {
            let outcome = try GhostHands.setValue(value: value, control: control, appSpec: appSpec)
            print(reportValue(outcome))
        } catch let error as GhostHandsError {
            fail("set-value", error)
        } catch {
            failUnexpected("set-value")
        }
    }

    /// Honest one-liner for a value-setting verb. VERIFIED quotes the observed
    /// before → after; DISPATCHED-UNVERIFIED states plainly that AX accepted the
    /// set but no value change was observed (the word 'unverified' is present),
    /// and exits 0 — it is not a failure, but it is NOT a success claim.
    static func reportValue(_ o: ValueOutcome) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            let how = o.exact ? "verified" : "verified (changed)"
            return "\(o.verb) \(o.intended.debugDescription) into \(o.name.debugDescription) "
                + "\(where_) — \(how): \(o.evidence ?? "changed")"
        }
        let was = o.valueAfter.map { $0.debugDescription } ?? "empty"
        return "set \(o.name.debugDescription) \(where_) via AXValue — AX accepted; "
            + "field value unchanged (\(was)) (effect unverified)"
    }

    // MARK: - doubleclick

    @MainActor
    static func runDoubleClick(_ rest: [String]) {
        guard rest.count >= 2 else { usage() }
        let name = rest[0]
        let appSpec = rest[1]
        do {
            let outcome = try GhostHands.doubleclick(name: name, appSpec: appSpec)
            print(reportAct(outcome))
        } catch let error as GhostHandsError {
            fail("doubleclick", error)
        } catch {
            failUnexpected("doubleclick")
        }
    }

    // MARK: - act

    @MainActor
    static func runAct(_ rest: [String]) {
        guard rest.count >= 3 else { usage() }
        let action = rest[0]
        let name = rest[1]
        let appSpec = rest[2]
        do {
            let outcome = try GhostHands.act(action: action, name: name, appSpec: appSpec)
            print(reportAct(outcome))
        } catch let error as GhostHandsError {
            // An unknown friendly action is a USAGE error (exit 2), distinct from
            // a control that rejects a known action (exit 1).
            if case .unknownAction = error {
                FileHandle.standardError.write(Data("act failed: \(error)\n".utf8))
                exit(2)
            }
            fail("act", error)
        } catch {
            failUnexpected("act")
        }
    }

    /// Honest one-liner for an action verb. VERIFIED quotes observed evidence;
    /// DISPATCHED-UNVERIFIED states plainly that AX accepted the action but
    /// nothing observable changed (exit 0).
    static func reportAct(_ o: ActOutcome) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            return "\(o.verbLabel) \(o.name.debugDescription) \(where_) — "
                + "verified: \(o.evidence ?? "changed")"
        }
        return "\(o.verbLabel) \(o.name.debugDescription) \(where_) — "
            + "\(o.action) accepted; no observable change (effect unverified)"
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
          ghosthands click "<name>" <app>             press a named control (AX, cursor-less)
          ghosthands type "<text>" "<field>" <app>    set a text field's value, then read it back
          ghosthands set-value "<v>" "<ctl>" <app>    set a checkbox/slider/popup, then read it back
          ghosthands doubleclick "<name>" <app>       open a row/file (AXOpen), verified by effect
          ghosthands act <action> "<name>" <app>      invoke a named AX action (see actions below)
          ghosthands snapshot <app> [--ax|--json]     dump the AX tree (pure read, default --ax)
          ghosthands find "<name>" <app>              does a named element exist? (exit 0/1)
          ghosthands shot <app> <out.png>             honest screenshot (refuses without Screen Recording)
          ghosthands version

          <action> for `act` = open | confirm | pick | show-menu | cancel | raise | increment | decrement

        <app> = bundle id, pid, or (partial) app name. Examples:
          ghosthands click "New Folder" Finder
          ghosthands type "hello" "Search" Safari
          ghosthands set-value "on" "Wi-Fi" "System Settings"
          ghosthands doubleclick "report.pdf" Finder
          ghosthands act increment "Volume" "System Settings"
          ghosthands snapshot Calculator --json
          ghosthands find "7" Calculator
          ghosthands shot Calculator /tmp/calc.png

        Honesty: every verb reports observed evidence only.
          - click is VERIFIED only on an observed change (incl. a named sibling witness,
            e.g. 'display 0 → 789'); else dispatched-unverified.
          - type / set-value set the value via AX then RE-READ it: VERIFIED only when the
            field reads back as the value (or demonstrably changed toward it); a setValue
            that AX accepts but does not change the field is reported dispatched-unverified,
            NEVER success. A secure (password) field is REFUSED — its value cannot be read
            back, so a set cannot be verified.
          - act/doubleclick verify by read-back where observable; actions with no in-AX
            observable (e.g. raise, show-menu) land as dispatched-unverified, never faked.
        shot writes a file ONLY for real captured pixels — it refuses (no file) when
        Screen Recording is not granted, never a black PNG.
        """
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }
}
