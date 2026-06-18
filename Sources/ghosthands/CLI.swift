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
        case "web":
            runWeb(Array(args.dropFirst()))
        case "snapshot":
            runSnapshot(Array(args.dropFirst()))
        case "find":
            runFind(Array(args.dropFirst()))
        case "shot":
            await runShot(Array(args.dropFirst()))
        case "click-at":
            await runClickAt(Array(args.dropFirst()))
        case "drag":
            await runDrag(Array(args.dropFirst()))
        case "replay":
            runReplay(Array(args.dropFirst()))
        case "record":
            runRecord(Array(args.dropFirst()))
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

    // MARK: - web (read | tabs)

    @MainActor
    static func runWeb(_ rest: [String]) {
        guard let sub = rest.first else { usage() }
        let tail = Array(rest.dropFirst())
        switch sub {
        case "read": runWebRead(tail)
        case "tabs": runWebTabs(tail)
        default: usage()
        }
    }

    @MainActor
    static func runWebRead(_ rest: [String]) {
        guard let browser = rest.first else { usage() }
        do {
            let result = try GhostHands.webRead(browser: browser)
            let body = WebDigest.render(result.entries)
            if !body.isEmpty { print(body) }
            // Honest footer to stderr: distinguish "no page surface" from a page
            // that is present but has no meaningful controls/text.
            let note: String
            if !result.hasWebArea {
                note = "— no AXWebArea (page) found in \(result.app); "
                    + "browser chrome only (nothing to read)"
            } else {
                note = "— \(result.count) page elements in \(result.app)"
            }
            FileHandle.standardError.write(Data((note + "\n").utf8))
        } catch let error as GhostHandsError {
            fail("web read", error)
        } catch {
            failUnexpected("web read")
        }
    }

    @MainActor
    static func runWebTabs(_ rest: [String]) {
        guard let browser = rest.first else { usage() }
        do {
            let result = try GhostHands.webTabs(browser: browser)
            for tab in result.tabs {
                let mark = tab.selected ? "* " : "  "
                print(mark + tab.title)
            }
            FileHandle.standardError.write(
                Data("— \(result.tabs.count) tabs in \(result.app)\n".utf8))
        } catch let error as GhostHandsError {
            fail("web tabs", error)
        } catch {
            failUnexpected("web tabs")
        }
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

    // MARK: - click-at (pixel)

    @MainActor
    static func runClickAt(_ rest: [String]) async {
        // `--visible` may appear in any order; the rest are positional x y app.
        let (mode, pos) = PixelFlags.parse(rest)
        guard pos.count >= 3 else { usage() }
        guard let x = Double(pos[0]) else { failBadCoord("click-at", pos[0]) }
        guard let y = Double(pos[1]) else { failBadCoord("click-at", pos[1]) }
        let appSpec = pos[2]
        do {
            let outcome = try await GhostHands.clickAt(x: x, y: y, appSpec: appSpec, mode: mode)
            print(reportPixel(outcome))
        } catch let error as GhostHandsError {
            fail("click-at", error)
        } catch {
            failUnexpected("click-at")
        }
    }

    // MARK: - drag (pixel)

    @MainActor
    static func runDrag(_ rest: [String]) async {
        // `--visible` may appear in any order; the rest are positional x1 y1 x2 y2 app.
        let (mode, pos) = PixelFlags.parse(rest)
        guard pos.count >= 5 else { usage() }
        guard let x1 = Double(pos[0]) else { failBadCoord("drag", pos[0]) }
        guard let y1 = Double(pos[1]) else { failBadCoord("drag", pos[1]) }
        guard let x2 = Double(pos[2]) else { failBadCoord("drag", pos[2]) }
        guard let y2 = Double(pos[3]) else { failBadCoord("drag", pos[3]) }
        let appSpec = pos[4]
        do {
            let outcome = try await GhostHands.drag(x1: x1, y1: y1, x2: x2, y2: y2,
                                                    appSpec: appSpec, mode: mode)
            print(reportPixel(outcome))
        } catch let error as GhostHandsError {
            fail("drag", error)
        } catch {
            failUnexpected("drag")
        }
    }

    /// Honest one-liner for a pixel poke. VERIFIED quotes the observed pixel diff;
    /// DISPATCHED-UNVERIFIED says plainly the event was dispatched but no pixel
    /// change was observed (or could not be observed) — exits 0, never a success
    /// claim. Pixel mode is more visible / less guaranteed than the AX verbs.
    static func reportPixel(_ o: PixelOutcome) -> String {
        let at = "(\(Int(o.x)),\(Int(o.y)))"
        // Label the visible HID exception so a moved cursor / focus steal is never
        // silent; the default invisible path adds nothing. The label also flags the
        // diff-vs-actuation split: the verdict diffs the TARGET app's AX-frontmost
        // window, but the HID click lands on whatever window is SCREEN-frontmost
        // under the point — so when windows overlap the two can differ, and the
        // verdict reflects the TARGET window's repaint, not proof the HID landed on
        // it. That only ever UNDER-claims (never a false verified), but say it.
        let tag = o.mode == .visible
            ? " [visible HID — cursor moved; diffs target window, HID hits screen-front window under point]"
            : ""
        if o.verified {
            let pct = String(format: "%.1f%%", o.changedFraction * 100)
            return "\(o.verb) \(at) in \(o.app)\(tag) — verified: pixel diff at \(at): "
                + "\(pct) of region changed"
        }
        if !o.observable {
            return "\(o.verb) \(at) in \(o.app)\(tag) — event dispatched; could not observe "
                + "(Screen Recording not granted — effect unverified)"
        }
        return "\(o.verb) \(at) in \(o.app)\(tag) — event dispatched; no observable pixel "
            + "change (effect unverified)"
    }

    static func failBadCoord(_ verb: String, _ raw: String) -> Never {
        fail(verb, .badCoordinate(raw))
    }

    // MARK: - replay

    @MainActor
    static func runReplay(_ rest: [String]) {
        // replay <flow.json> [--keep-going], flag in any order.
        var flowPath: String?
        var keepGoing = false
        for arg in rest {
            switch arg {
            case "--keep-going": keepGoing = true
            default: if flowPath == nil { flowPath = arg }
            }
        }
        guard let flowPath else { usage() }
        do {
            let run = try GhostHands.replay(flowPath: flowPath, keepGoing: keepGoing) {
                index, total, line in
                print("step \(index)/\(total): \(line)")
            }
            let s = run.summary
            // Honest summary to stderr (stdout carries the per-step verdicts).
            var note = "— \(s.executed)/\(run.total) step(s): "
                + "\(s.verified) verified, \(s.dispatched) unverified, \(s.refused) refused"
            if s.stoppedEarly { note += " (stopped on refuse — use --keep-going to continue)" }
            FileHandle.standardError.write(Data((note + "\n").utf8))
            // Exit 0 iff no step refused; non-zero otherwise (the pure policy).
            exit(s.exitCode)
        } catch let error as FlowCodec.FlowError {
            fail("replay", error)
        } catch let error as GhostHandsError {
            fail("replay", error)
        } catch {
            failUnexpected("replay")
        }
    }

    // MARK: - record

    @MainActor
    static func runRecord(_ rest: [String]) {
        // record <flow.json> <verb> <args...>
        guard rest.count >= 2 else { usage() }
        let flowPath = rest[0]
        let verb = rest[1]
        let verbArgs = Array(rest.dropFirst(2))
        guard let step = parseStep(verb: verb, args: verbArgs) else { usage() }
        do {
            let run = try GhostHands.record(step, into: flowPath)
            print(run.line)
            if run.appended {
                FileHandle.standardError.write(
                    Data("— appended to \(flowPath) (now \(run.stepCount) step(s))\n".utf8))
            } else {
                FileHandle.standardError.write(
                    Data("— NOT appended (step refused; flow left at \(run.stepCount) step(s))\n".utf8))
                // A refused step is a non-zero exit, exactly like running the verb.
                exit(1)
            }
        } catch let error as FlowCodec.FlowError {
            fail("record", error)
        } catch let error as GhostHandsError {
            fail("record", error)
        } catch {
            failUnexpected("record")
        }
    }

    /// Build a `Step` from a verb token + its positional args, using the SAME
    /// arity/order as the direct verbs (app spec last). nil → usage error.
    static func parseStep(verb: String, args: [String]) -> Step? {
        switch verb {
        case "click":
            guard args.count >= 2 else { return nil }
            return .click(name: args[0], app: args[1])
        case "type":
            guard args.count >= 3 else { return nil }
            return .type(text: args[0], field: args[1], app: args[2])
        case "set-value":
            guard args.count >= 3 else { return nil }
            return .setValue(value: args[0], control: args[1], app: args[2])
        case "doubleclick":
            guard args.count >= 2 else { return nil }
            return .doubleclick(name: args[0], app: args[1])
        case "act":
            guard args.count >= 3 else { return nil }
            return .act(action: args[0], name: args[1], app: args[2])
        default:
            return nil
        }
    }

    // MARK: - failure helpers

    static func fail(_ verb: String, _ error: GhostHandsError) -> Never {
        FileHandle.standardError.write(Data("\(verb) failed: \(error)\n".utf8))
        exit(1)
    }

    static func fail(_ verb: String, _ error: FlowCodec.FlowError) -> Never {
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
          ghosthands web read <browser>               page-scoped digest (chrome stripped, AX only)
          ghosthands web tabs <browser>               list open tabs (* = selected); refuses if not exposed
          ghosthands find "<name>" <app>              does a named element exist? (exit 0/1)
          ghosthands shot <app> <out.png>             honest screenshot (refuses without Screen Recording)
          ghosthands click-at <x> <y> <app> [--visible]           left click at a GLOBAL screen point (pixel, verify-by-diff)
          ghosthands drag <x1> <y1> <x2> <y2> <app> [--visible]   press-move-release between two GLOBAL points (pixel)
          ghosthands replay <flow.json> [--keep-going] run a recorded flow in order (stops on refuse)
          ghosthands record <flow.json> <verb> <args> run a verb AND append it to the flow if it didn't refuse
          ghosthands version

          <action> for `act` = open | confirm | pick | show-menu | cancel | raise | increment | decrement

        <app> = bundle id, pid, or (partial) app name. Examples:
          ghosthands click "New Folder" Finder
          ghosthands type "hello" "Search" Safari
          ghosthands set-value "on" "Wi-Fi" "System Settings"
          ghosthands doubleclick "report.pdf" Finder
          ghosthands act increment "Volume" "System Settings"
          ghosthands snapshot Calculator --json
          ghosthands web read Brave
          ghosthands web tabs Chrome
          ghosthands find "7" Calculator
          ghosthands shot Calculator /tmp/calc.png
          ghosthands click-at 480 300 Calculator
          ghosthands drag 100 200 400 200 Preview
          ghosthands record /tmp/login.json type "alice" "Username" Safari
          ghosthands replay /tmp/login.json

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
          - click-at / drag are the PIXEL tier (no AX element; coords from the caller).
            They VERIFY by a screenshot diff of the click neighborhood: VERIFIED only
            on an observed pixel change; otherwise the event is dispatched-unverified
            (NEVER success), and they REFUSE a point outside the target window. Two
            delivery modes (the INVISIBILITY axis):
              default (invisible best-effort): post the mouse events straight to the
                app's pid (CGEventPostToPid) — cursor-less, no warp, background-capable.
                But postToPid is coordinate-only (no OS hit-test), so a backgrounded
                or non-key AppKit window — and some non-AppKit / game surfaces — may
                IGNORE it (dispatched-unverified). It does NOT actuate a window that
                only responds to a real OS click.
              --visible (LABELLED exception): warp the REAL cursor to the point and
                post a real HID click via the .cghidEventTap, so the WindowServer
                hit-tests and ACTUATES the window under the point (the path that lands
                a backgrounded AppKit window postToPid could not reach). It MOVES /
                flickers the visible cursor, and macOS routes the HID mouse to whatever
                window is FRONTMOST under the point (an OS wall) — so --visible is NOT
                invisible, may FOREGROUND / steal focus, and cannot click a truly
                background window without raising it. The cursor is saved and restored.
                One more honesty caveat: the diff measures the TARGET app's AX-frontmost
                window, but the HID lands on whatever window is SCREEN-frontmost under
                the point — when windows OVERLAP these can differ, so a verified /
                unverified verdict reflects the TARGET window's repaint, not proof the
                HID landed on it (this only ever under-claims, never a false verified).
            Pixel mode is MORE visible / less guaranteed than the AX verbs — prefer
            click/act when an AX element exists.
        """
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }
}
