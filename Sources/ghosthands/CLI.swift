import CoreGraphics
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
        case "right-click", "rightclick":
            runRightClick(Array(args.dropFirst()))
        case "act":
            runAct(Array(args.dropFirst()))
        case "focus":
            runFocus(Array(args.dropFirst()))
        case "navigate":
            runNavigate(Array(args.dropFirst()))
        case "web":
            await runWeb(Array(args.dropFirst()))
        case "windows":
            runWindows(Array(args.dropFirst()))
        case "window":
            runWindow(Array(args.dropFirst()))
        case "snapshot":
            runSnapshot(Array(args.dropFirst()))
        case "extract":
            runExtract(Array(args.dropFirst()))
        case "find":
            runFind(Array(args.dropFirst()))
        case "wait":
            runWait(Array(args.dropFirst()))
        case "shot":
            await runShot(Array(args.dropFirst()))
        case "click-at":
            await runClickAt(Array(args.dropFirst()))
        case "drag":
            await runDrag(Array(args.dropFirst()))
        case "scroll":
            runScroll(Array(args.dropFirst()))
        case "dialog":
            runDialog(Array(args.dropFirst()))
        case "key":
            runKey(Array(args.dropFirst()))
        case "clipboard", "clip":
            runClipboard(Array(args.dropFirst()))
        case "install":
            await runInstall(Array(args.dropFirst()))
        case "replay":
            runReplay(Array(args.dropFirst()))
        case "record":
            runRecord(Array(args.dropFirst()))
        default:
            usage()
        }
    }

    // MARK: - locator flags (shared by the named-control verbs)

    /// Scan the OPT-IN disambiguator flags out of `args` (in any order, mirroring
    /// the `--in` / `--window` / `--visible` flag loops) and return the parsed
    /// `LocatorSpec` plus the remaining positionals in order:
    ///   --nth <i>       pick the i-th match (0-based, deterministic tree order)
    ///   --role <AXRole> restrict candidates to a given AX role
    ///   --text <substr> restrict candidates to those whose label/value contains <substr>
    /// With NONE of these present the spec is `.none` and the resolve path is
    /// byte-for-byte the pre-flag behavior (refuse-on-ambiguous intact). A
    /// `--nth` whose value is not an integer is left UNSET (the value token is
    /// consumed but ignored) — the resolve then refuses on ambiguity as if no
    /// `--nth` were given, never silently picking index 0.
    static func parseLocator(_ args: [String]) -> (locator: LocatorSpec, positional: [String]) {
        var role: String?
        var text: String?
        var nth: Int?
        var positional: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--nth":
                if i + 1 < args.count { nth = Int(args[i + 1]); i += 2 } else { i += 1 }
            case "--role":
                if i + 1 < args.count { role = args[i + 1]; i += 2 } else { i += 1 }
            case "--text":
                if i + 1 < args.count { text = args[i + 1]; i += 2 } else { i += 1 }
            default:
                positional.append(args[i]); i += 1
            }
        }
        return (LocatorSpec(role: role, text: text, nth: nth), positional)
    }

    // MARK: - click

    @MainActor
    static func runClick(_ rest: [String]) {
        let (locator, pos) = parseLocator(rest)
        guard pos.count >= 2 else { usage() }
        let name = pos[0]
        let appSpec = pos[1]
        do {
            let outcome = try GhostHands.click(name: name, appSpec: appSpec, locator: locator)
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
        let (locator, pos) = parseLocator(rest)
        guard pos.count >= 3 else { usage() }
        let text = pos[0]
        let field = pos[1]
        let appSpec = pos[2]
        do {
            let outcome = try GhostHands.type(text: text, field: field, appSpec: appSpec,
                                              locator: locator)
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
        let (locator, pos) = parseLocator(rest)
        guard pos.count >= 3 else { usage() }
        let value = pos[0]
        let control = pos[1]
        let appSpec = pos[2]
        do {
            let outcome = try GhostHands.setValue(value: value, control: control,
                                                  appSpec: appSpec, locator: locator)
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
        let (locator, pos) = parseLocator(rest)
        guard pos.count >= 2 else { usage() }
        let name = pos[0]
        let appSpec = pos[1]
        do {
            let outcome = try GhostHands.doubleclick(name: name, appSpec: appSpec, locator: locator)
            print(reportAct(outcome))
        } catch let error as GhostHandsError {
            fail("doubleclick", error)
        } catch {
            failUnexpected("doubleclick")
        }
    }

    // MARK: - right-click

    @MainActor
    static func runRightClick(_ rest: [String]) {
        // `--visible` may appear in any order (REUSE PixelFlags — only the pixel
        // fallback honours it; the AX route is always invisible); the locator
        // disambiguators (--role/--text/--nth) too; the rest are positional:
        // <name> <app>. Parse PixelFlags first, then the locator off its leftovers.
        let (mode, afterVisible) = PixelFlags.parse(rest)
        let (locator, pos) = parseLocator(afterVisible)
        guard pos.count >= 2 else { usage() }
        let name = pos[0]
        let appSpec = pos[1]
        do {
            let outcome = try GhostHands.rightClick(name: name, appSpec: appSpec, mode: mode,
                                                    locator: locator)
            print(reportRightClick(outcome))
        } catch let error as GhostHandsError {
            fail("right-click", error)
        } catch {
            failUnexpected("right-click")
        }
    }

    /// Honest one-liner for a right-click. VERIFIED quotes the observed
    /// context-menu appearance (the before → after AXMenu count); otherwise the
    /// action is dispatched-unverified (the menu was not observed — exit 0, never
    /// a success claim). The ROUTE is named (AXShowMenu vs pixel) so the weaker
    /// pixel-route guarantees are explicit, and the `.visible` HID exception is
    /// LABELLED so a moved cursor / focus steal is never silent.
    static func reportRightClick(_ o: RightClickOutcome) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        let via: String
        switch o.route {
        case .axShowMenu:
            via = " [via AXShowMenu — invisible]"
        case .pixel:
            via = o.mode == .visible
                ? " [via pixel right-click — visible HID; cursor moved, may steal focus]"
                : " [via pixel right-click — invisible CGEventPostToPid; postToPid is "
                    + "coordinate-only, a background/non-key surface may ignore it]"
        }
        if o.verified {
            return "right-clicked \(o.name.debugDescription) \(where_)\(via) — "
                + "verified: \(o.evidence ?? "context menu appeared")"
        }
        return "right-clicked \(o.name.debugDescription) \(where_)\(via) — action "
            + "dispatched; no context menu observed (effect unverified)"
    }

    // MARK: - act

    @MainActor
    static func runAct(_ rest: [String]) {
        let (locator, pos) = parseLocator(rest)
        guard pos.count >= 3 else { usage() }
        let action = pos[0]
        let name = pos[1]
        let appSpec = pos[2]
        do {
            let outcome = try GhostHands.act(action: action, name: name, appSpec: appSpec,
                                             locator: locator)
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

    // MARK: - focus

    @MainActor
    static func runFocus(_ rest: [String]) {
        let (locator, pos) = parseLocator(rest)
        guard pos.count >= 2 else { usage() }
        let name = pos[0]
        let appSpec = pos[1]
        do {
            let outcome = try GhostHands.focus(name: name, appSpec: appSpec, locator: locator)
            print(reportFocus(outcome))
        } catch let error as GhostHandsError {
            fail("focus", error)
        } catch {
            failUnexpected("focus")
        }
    }

    /// Honest one-liner for `focus`. VERIFIED quotes the AXFocused read-back;
    /// DISPATCHED-UNVERIFIED states plainly that AX accepted the focus set but
    /// AXFocused did not read back true (false, or unreadable on this control) —
    /// exits 0, never a focus claim we cannot observe.
    static func reportFocus(_ o: FocusOutcome) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            return "focused \(o.name.debugDescription) \(where_) — "
                + "verified: \(o.evidence ?? "AXFocused → true")"
        }
        let read = o.focusedAfter.map { $0 ? "true" : "false" } ?? "unreadable"
        return "focus \(o.name.debugDescription) \(where_) — AXFocused set accepted; "
            + "read back \(read) (effect unverified)"
    }

    // MARK: - web (read | tabs)

    @MainActor
    static func runWeb(_ rest: [String]) async {
        guard let sub = rest.first else { usage() }
        let tail = Array(rest.dropFirst())
        switch sub {
        case "read": await runWebRead(tail)
        case "tabs": await runWebTabs(tail)
        case "click": await runWebClick(tail)
        case "fill": await runWebFill(tail)
        case "html": await runWebHtml(tail)
        case "eval": await runWebEval(tail)
        default: usage()
        }
    }

    /// Scan `--cdp` / `--ax` / `--debug-port <N>` / `--relaunch` out of the args
    /// (in any order) and return the lens, port, relaunch flag, and remaining
    /// positionals — mirroring the snapshot `--ax|--json` loop and
    /// `parseWindowSelector`. Default lens is `.auto` (CDP-when-reachable, else
    /// AX), default port 9222, relaunch OFF.
    ///
    /// `--relaunch` is the CONSENT GATE: only meaningful with `--cdp`, default OFF.
    /// When the debug port is CLOSED and `--relaunch` is NOT given, behavior is
    /// UNCHANGED (refuse). When given, a closed port launches a NEW, ISOLATED
    /// throwaway browser instance for automation — never the user's real profile,
    /// never silently.
    static func parseWebLens(_ args: [String])
        -> (lens: WebLens, port: Int, relaunch: Bool, positional: [String]) {
        var lens: WebLens = .auto
        var port = 9222
        var relaunch = false
        var positional: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--cdp": lens = .cdp; i += 1
            case "--ax": lens = .ax; i += 1
            case "--relaunch": relaunch = true; i += 1
            case "--debug-port":
                if i + 1 < args.count, let p = Int(args[i + 1]) { port = p; i += 2 }
                else { i += 1 }
            default: positional.append(args[i]); i += 1
            }
        }
        return (lens, port, relaunch, positional)
    }

    @MainActor
    static func runWebRead(_ rest: [String]) async {
        let (lens, port, relaunch, positional) = parseWebLens(rest)
        guard let browser = positional.first else { usage() }
        do {
            let (result, served) = try await GhostHands.webRead(
                browser: browser, lens: lens, debugPort: port, relaunch: relaunch)
            let body = WebDigest.render(result.entries)
            if !body.isEmpty { print(body) }
            // Honest footer to stderr: distinguish "no page surface" from a page
            // that is present but has no meaningful controls/text, AND name the
            // lens that served the read.
            let via = lensLabel(served)
            let note: String
            if !result.hasWebArea {
                note = "— no AXWebArea (page) found in \(result.app); "
                    + "browser chrome only (nothing to read) (\(via))"
            } else {
                note = "— \(result.count) page elements in \(result.app) (\(via))"
            }
            FileHandle.standardError.write(Data((note + "\n").utf8))
        } catch let error as GhostHandsError {
            fail("web read", error)
        } catch {
            failUnexpected("web read")
        }
    }

    @MainActor
    static func runWebTabs(_ rest: [String]) async {
        let (lens, port, relaunch, positional) = parseWebLens(rest)
        guard let browser = positional.first else { usage() }
        do {
            let (result, served) = try await GhostHands.webTabs(
                browser: browser, lens: lens, debugPort: port, relaunch: relaunch)
            for tab in result.tabs {
                let mark = tab.selected ? "* " : "  "
                print(mark + tab.title)
            }
            FileHandle.standardError.write(
                Data("— \(result.tabs.count) tabs in \(result.app) (\(lensLabel(served)))\n".utf8))
        } catch let error as GhostHandsError {
            fail("web tabs", error)
        } catch {
            failUnexpected("web tabs")
        }
    }

    /// The honest "(via …)" lens label for the stderr footer.
    static func lensLabel(_ served: GhostHands.ServedLens) -> String {
        switch served {
        case let .cdp(port): return "via CDP, port \(port)"
        case .ax: return "via AX"
        }
    }

    // MARK: - web click / web fill (CDP-only DOM-selector actuation)

    @MainActor
    static func runWebClick(_ rest: [String]) async {
        let (lens, port, relaunch, positional) = parseWebLens(rest)
        // web click <selector> <browser>
        guard positional.count >= 2 else { usage() }
        let selector = positional[0]
        let browser = positional[1]
        do {
            let result = try await GhostHands.webClick(
                selector: selector, browser: browser, lens: lens, debugPort: port,
                relaunch: relaunch)
            print(reportWebActuate(result))
        } catch let error as GhostHandsError {
            failWebActuate("web click", error)
        } catch {
            failUnexpected("web click")
        }
    }

    @MainActor
    static func runWebFill(_ rest: [String]) async {
        let (lens, port, relaunch, positional) = parseWebLens(rest)
        // web fill <selector> <text> <browser>
        guard positional.count >= 3 else { usage() }
        let selector = positional[0]
        let text = positional[1]
        let browser = positional[2]
        do {
            let result = try await GhostHands.webFill(
                selector: selector, text: text, browser: browser, lens: lens,
                debugPort: port, relaunch: relaunch)
            print(reportWebActuate(result))
        } catch let error as GhostHandsError {
            failWebActuate("web fill", error)
        } catch {
            failUnexpected("web fill")
        }
    }

    /// Honest one-liner for a selector actuation. VERIFIED quotes the observed
    /// evidence (a navigation, or a value read-back); DISPATCHED-UNVERIFIED states
    /// plainly that the event was dispatched but the effect is unproven (exit 0,
    /// never a success claim). A footer names the lens (CDP, port N).
    static func reportWebActuate(_ r: GhostHands.WebActuateResult) -> String {
        let sel = r.selector.debugDescription
        let footer = "(via CDP, port \(r.port))"
        switch r.verdict {
        case let .verified(evidence):
            return "\(r.verb) \(sel) in \(r.app) — verified: \(evidence) \(footer)"
        case let .dispatchedUnverified(reason):
            return "\(r.verb) \(sel) in \(r.app) — \(reason) \(footer)"
        }
    }

    /// A `web click`/`web fill` refuse that is a USAGE-class error (the selector
    /// verbs were forced onto `--ax`) exits 2; every other refuse exits 1 (mirrors
    /// runAct's `.unknownAction` wiring).
    static func failWebActuate(_ verb: String, _ error: GhostHandsError) -> Never {
        if case .selectorNeedsCDP = error {
            FileHandle.standardError.write(Data("\(verb) failed: \(error)\n".utf8))
            exit(2)
        }
        fail(verb, error)
    }

    // MARK: - web html / web eval (CDP-only DOM read verbs — Slice 3)

    @MainActor
    static func runWebHtml(_ rest: [String]) async {
        let (lens, port, relaunch, positional) = parseWebLens(rest)
        // web html <selector> <browser>
        guard positional.count >= 2 else { usage() }
        let selector = positional[0]
        let browser = positional[1]
        do {
            let result = try await GhostHands.webHtml(
                selector: selector, browser: browser, lens: lens, debugPort: port,
                relaunch: relaunch)
            print(WebHtml.render(result.shaped))
            // Honest footer to stderr: name the resolved selector + the lens.
            FileHandle.standardError.write(Data(
                "— \(result.selector) in \(result.app) (via CDP, port \(result.port))\n".utf8))
        } catch let error as GhostHandsError {
            failWebActuate("web html", error)
        } catch {
            failUnexpected("web html")
        }
    }

    @MainActor
    static func runWebEval(_ rest: [String]) async {
        let (lens, port, relaunch, positional) = parseWebLens(rest)
        // web eval <js> <browser>
        guard positional.count >= 2 else { usage() }
        let js = positional[0]
        let browser = positional[1]
        do {
            let result = try await GhostHands.webEval(
                js: js, browser: browser, lens: lens, debugPort: port,
                relaunch: relaunch)
            print(result.value)
            FileHandle.standardError.write(Data(
                "— evaluated in \(result.app) (via CDP, port \(result.port))\n".utf8))
        } catch let error as GhostHandsError {
            failWebActuate("web eval", error)
        } catch {
            failUnexpected("web eval")
        }
    }

    // MARK: - navigate

    @MainActor
    static func runNavigate(_ rest: [String]) {
        // navigate "<url>" [browser]. URL required; browser optional → auto-pick
        // a running Chromium.
        guard let url = rest.first else { usage() }
        let browser = rest.count >= 2 ? rest[1] : nil
        do {
            let outcome = try GhostHands.navigate(url: url, browser: browser)
            print(reportNavigate(outcome))
        } catch let error as GhostHandsError {
            fail("navigate", error)
        } catch {
            failUnexpected("navigate")
        }
    }

    /// Honest one-liner for a navigate. VERIFIED quotes the landed URL (and title)
    /// as evidence; DISPATCHED-UNVERIFIED states plainly that the load was issued
    /// but the landed page could not be confirmed (the word "unverified" is
    /// present) — exits 0, NEVER a "navigated"/success claim. The browser is named
    /// (with "(auto-picked)" when `[browser]` was omitted).
    static func reportNavigate(_ o: GhostHands.NavigateOutcome) -> String {
        let pick = o.autoPicked ? " (auto-picked)" : ""
        let into = "in \(o.app)\(pick)"
        if o.verified {
            return "navigated to \(o.requestedURL.debugDescription) \(into) — "
                + "verified: \(o.evidence ?? "page changed")"
        }
        return "load issued for \(o.requestedURL.debugDescription) \(into) — "
            + "could not confirm landed page (effect unverified): "
            + "\(o.evidence ?? "no readable page URL")"
    }

    // MARK: - windows (read)

    @MainActor
    static func runWindows(_ rest: [String]) {
        guard let appSpec = rest.first else { usage() }
        do {
            let result = try GhostHands.windows(appSpec: appSpec)
            for (i, w) in result.windows.enumerated() {
                print(reportWindowLine(index: i, window: w))
            }
            FileHandle.standardError.write(
                Data("— \(result.count) window(s) in \(result.app)\n".utf8))
        } catch let error as GhostHandsError {
            fail("windows", error)
        } catch {
            failUnexpected("windows")
        }
    }

    /// One honest line per window: id, title, frame, display, and the AX flags.
    /// A nil id/title/display is shown as unknown ('?' / '(untitled)'), never faked.
    static func reportWindowLine(index: Int, window w: WindowInfo) -> String {
        let id = w.id.map(String.init) ?? "?"
        let title = (w.title?.isEmpty == false) ? w.title!.debugDescription : "(untitled)"
        let f = w.frame
        let frame = "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
        let display = w.screenIndex.map(String.init) ?? "off-screen"
        var flags = ""
        if w.isMain { flags += " [main]" }
        if w.isFocused { flags += " [focused]" }
        if w.minimized { flags += " [minimized]" }
        return "[#\(index)] id=\(id) \(title)  \(frame)  display \(display)\(flags)"
    }

    // MARK: - window (move | resize | raise)

    @MainActor
    static func runWindow(_ rest: [String]) {
        guard let sub = rest.first else { usage() }
        let tail = Array(rest.dropFirst())
        switch sub {
        case "move": runWindowMove(tail)
        case "resize": runWindowResize(tail)
        case "raise": runWindowRaise(tail)
        default: usage()
        }
    }

    /// Scan `--window <id|title>` out of the args (in any order) and return the
    /// remaining positionals in order, mirroring the snapshot/replay flag loops.
    static func parseWindowSelector(_ args: [String]) -> (selector: WindowSelector?, positional: [String]) {
        var selector: WindowSelector?
        var positional: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--window", i + 1 < args.count {
                selector = WindowSelector.parse(args[i + 1])
                i += 2
            } else {
                positional.append(args[i])
                i += 1
            }
        }
        return (selector, positional)
    }

    @MainActor
    static func runWindowMove(_ rest: [String]) {
        let (selector, pos) = parseWindowSelector(rest)
        guard pos.count >= 3 else { usage() }
        guard let x = Double(pos[0]) else { failBadCoord("window move", pos[0]) }
        guard let y = Double(pos[1]) else { failBadCoord("window move", pos[1]) }
        let appSpec = pos[2]
        do {
            let outcome = try GhostHands.windowMove(x: x, y: y, appSpec: appSpec, selector: selector)
            print(reportWindowMutate(outcome))
        } catch let error as GhostHandsError {
            fail("window move", error)
        } catch {
            failUnexpected("window move")
        }
    }

    @MainActor
    static func runWindowResize(_ rest: [String]) {
        let (selector, pos) = parseWindowSelector(rest)
        guard pos.count >= 3 else { usage() }
        guard let w = Double(pos[0]) else { failBadCoord("window resize", pos[0]) }
        guard let h = Double(pos[1]) else { failBadCoord("window resize", pos[1]) }
        let appSpec = pos[2]
        do {
            let outcome = try GhostHands.windowResize(w: w, h: h, appSpec: appSpec, selector: selector)
            print(reportWindowMutate(outcome))
        } catch let error as GhostHandsError {
            fail("window resize", error)
        } catch {
            failUnexpected("window resize")
        }
    }

    @MainActor
    static func runWindowRaise(_ rest: [String]) {
        let (selector, pos) = parseWindowSelector(rest)
        guard let appSpec = pos.first else { usage() }
        do {
            let outcome = try GhostHands.windowRaise(appSpec: appSpec, selector: selector)
            print(reportWindowRaise(outcome))
        } catch let error as GhostHandsError {
            fail("window raise", error)
        } catch {
            failUnexpected("window raise")
        }
    }

    /// Honest one-liner for move/resize. VERIFIED quotes before → after frame;
    /// CLAMPED says the OS constrained it to the ACTUAL landing (honest dispatched,
    /// exit 0); DISPATCHED says AX accepted but the value is unchanged (effect
    /// unverified). Never a fake success.
    static func reportWindowMutate(_ o: WindowMutateOutcome) -> String {
        let who = windowLabel(title: o.windowTitle, id: o.windowID, app: o.app)
        let before = rectStr(o.frameBefore)
        let after = rectStr(o.frameAfter)
        if o.verified {
            return "\(o.verb) \(who) — verified: \(before) → \(after)"
        }
        if o.clamped {
            return "\(o.verb) \(who) — AX accepted; OS constrained to \(after) "
                + "(requested elsewhere — effect partially landed, honest dispatched)"
        }
        let what = o.verb == "move" ? "position" : "size"
        return "\(o.verb) \(who) — AX accepted; \(what) unchanged (\(after)) "
            + "(effect unverified)"
    }

    /// Honest one-liner for raise — ALWAYS dispatched-unverified (z-order has no AX
    /// read-back). Never claims app activation.
    static func reportWindowRaise(_ o: WindowRaiseOutcome) -> String {
        let who = windowLabel(title: o.windowTitle, id: o.windowID, app: o.app)
        return "raise \(who) — AXRaise dispatched; stacking change not observable "
            + "in AX (unverified, app not activated)"
    }

    static func windowLabel(title: String?, id: CGWindowID?, app: String) -> String {
        let t = (title?.isEmpty == false) ? title!.debugDescription : "(untitled)"
        let idPart = id.map { " id=\($0)" } ?? ""
        return "\(t)\(idPart) in \(app)"
    }

    static func rectStr(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
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

    // MARK: - extract

    @MainActor
    static func runExtract(_ rest: [String]) {
        // Accept flags in any order: `--in <name>` (consumes the next token); the
        // first leftover positional is the app spec. Mirrors the scroll `--in` loop.
        var appSpec: String?
        var container: String?
        var i = 0
        while i < rest.count {
            if rest[i] == "--in", i + 1 < rest.count {
                container = rest[i + 1]
                i += 2
            } else {
                if appSpec == nil { appSpec = rest[i] }
                i += 1
            }
        }
        guard let appSpec else { usage() }
        do {
            let result = try GhostHands.extract(appSpec: appSpec, container: container)
            let body = TableRender.render(result.model)
            if !body.isEmpty { print(body) }
            // Honest footer to stderr: the row count (header excluded), the
            // container read, and whether a header was present. A present-but-empty
            // table reports 0 rows here — honest empty, never a refuse.
            let head = result.model.header != nil ? " (with header)" : ""
            let note = "— \(result.rowCount) row(s) from \(result.container.debugDescription) "
                + "in \(result.app)\(head)\n"
            FileHandle.standardError.write(Data(note.utf8))
        } catch let error as GhostHandsError {
            fail("extract", error)
        } catch {
            failUnexpected("extract")
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

    // MARK: - wait

    @MainActor
    static func runWait(_ rest: [String]) {
        // Flags in any order: --gone (bool), --timeout <seconds>, --interval <ms>.
        // The remaining positionals are <name> <app>.
        var gone = false
        var timeout: TimeInterval = 5
        var interval: TimeInterval = 0.15   // 150 ms default poll cadence
        var pos: [String] = []
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--gone":
                gone = true
            case "--timeout":
                let raw = i + 1 < rest.count ? rest[i + 1] : nil
                // The deadline MUST be finite and positive: a non-finite timeout
                // (`inf`/`nan`) or a non-positive one would defeat the verb's
                // central guarantee — a hard wall-clock wall. `inf` polls forever
                // (deadline never passes); `nan` and `<= 0` collapse to exactly one
                // poll with a garbage deadline. Refuse before spinning.
                guard let s = raw.flatMap(Double.init), s.isFinite, s > 0 else {
                    failWaitArg("--timeout", raw)
                }
                timeout = s; i += 1
            case "--interval":
                let raw = i + 1 < rest.count ? rest[i + 1] : nil
                // The poll cadence must be finite and non-negative. A negative
                // interval is a CPU-hot busy-spin (the deadline still bounds it, but
                // the cadence is silently not what was asked); `nan`/`inf` are
                // nonsense naps. 0 is allowed — it means "poll back-to-back" (the
                // loop skips the sleep when interval <= 0).
                guard let ms = raw.flatMap(Double.init), ms.isFinite, ms >= 0 else {
                    failWaitArg("--interval", raw)
                }
                interval = ms / 1000; i += 1
            default:
                pos.append(rest[i])
            }
            i += 1
        }
        guard pos.count >= 2 else { usage() }
        let name = pos[0]
        let appSpec = pos[1]
        do {
            let outcome = try GhostHands.wait(name: name, appSpec: appSpec,
                                              wantGone: gone, timeout: timeout,
                                              interval: interval)
            print(reportWait(outcome))
            // exit 0 — the condition was OBSERVED met.
        } catch let error as GhostHandsError {
            // A wait that times out is the EXPECTED refuse → nonzero exit (the
            // honesty boundary: the condition was never observed). It reuses the
            // standard fail() exit-1 path; the message names it as a timeout.
            fail("wait", error)
        } catch {
            failUnexpected("wait")
        }
    }

    /// Honest one-liner for a met wait. ALWAYS quotes the OBSERVED evidence —
    /// elapsed seconds + poll count — because a `WaitOutcome` only ever exists for
    /// a condition that was observed met (a timeout is a thrown refuse, never an
    /// outcome). Names which sense was satisfied (appeared vs disappeared).
    static func reportWait(_ o: WaitOutcome) -> String {
        let cond = o.wantedGone ? "gone from" : "present in"
        let secs = String(format: "%.2f", o.elapsed)
        return "\(o.name.debugDescription) \(cond) \(o.app) — observed after "
            + "\(secs)s (\(o.polls) poll\(o.polls == 1 ? "" : "s"))"
    }

    /// A bad --timeout/--interval value is a USAGE error (exit 2), mirroring the
    /// scroll bad-amount wiring — we refuse before spinning rather than coerce a
    /// garbage deadline. "Bad" is not just non-numeric: a non-finite (`inf`/`nan`)
    /// or out-of-range value (`--timeout` must be > 0, `--interval` must be >= 0)
    /// is rejected here too, because it would defeat the hard wall-clock deadline.
    static func failWaitArg(_ flag: String, _ raw: String?) -> Never {
        let v = raw?.debugDescription ?? "(missing)"
        let want = flag == "--timeout"
            ? "a finite number > 0"
            : "a finite number >= 0"
        FileHandle.standardError.write(
            Data("wait failed: \(flag) expects \(want), got \(v)\n".utf8))
        exit(2)
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

    // MARK: - drag (pixel coords OR element-to-element)

    @MainActor
    static func runDrag(_ rest: [String]) async {
        // `--visible` may appear in any order. `drag` has TWO forms that share the
        // verb, told apart by their positional shape (mirroring how `act` overloads):
        //   - PIXEL coords:  drag <x1> <y1> <x2> <y2> <app>   (5 positionals, all-numeric coords)
        //   - ELEMENT names: drag "<from>" "<to>" <app>       (3 positionals, names not numbers)
        // We route to the element form whenever there are EXACTLY 3 positionals — the
        // arity alone is unambiguous: a pixel drag needs 5 (x1 y1 x2 y2 app), so a
        // 3-positional drag can NEVER be a valid pixel drag, and routing on count
        // (not on "first two aren't numbers") keeps numerically-NAMED elements
        // reachable — e.g. `drag "5" "7" Calculator` drags keypad button 5 onto 7
        // instead of silently falling through to the pixel parser and printing usage.
        // Anything else (4 positionals, 6+, etc.) falls through to the pixel parser,
        // which reports the precise coord/arity error.
        let (mode, pos) = PixelFlags.parse(rest)
        if pos.count == 3 {
            await runDragElement(from: pos[0], to: pos[1], appSpec: pos[2], mode: mode)
            return
        }
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

    /// The ELEMENT-to-element drag form: resolve both named elements, aim at their
    /// centers, post a pixel drag, and witness by re-resolving the from-element's
    /// frame. Honest about VERIFIED (observed move/vanish) vs dispatched-unverified.
    @MainActor
    static func runDragElement(from: String, to: String, appSpec: String,
                               mode: PixelMode) async {
        do {
            let outcome = try GhostHands.dragElement(from: from, to: to,
                                                     appSpec: appSpec, mode: mode)
            print(reportDragElement(outcome))
        } catch let error as GhostHandsError {
            fail("drag", error)
        } catch {
            failUnexpected("drag")
        }
    }

    /// Honest one-liner for an element-to-element drag. VERIFIED quotes the
    /// observed from-element move/vanish; otherwise the drag is
    /// dispatched-unverified (events sent, no observable move — exit 0, never a
    /// success claim). The `.visible` HID exception is LABELLED so a moved cursor /
    /// focus steal is never silent; the invisible default adds nothing.
    static func reportDragElement(_ o: DragElementOutcome) -> String {
        let route = "\(o.from.debugDescription) → \(o.to.debugDescription) in \(o.app)"
        let tag = o.mode == .visible
            ? " [visible HID — cursor moved; events route by screen geometry, may steal focus]"
            : " [invisible CGEventPostToPid — postToPid is coordinate-only; a "
                + "background/non-key surface may ignore the drag]"
        if o.verified {
            return "dragged \(route)\(tag) — verified: \(o.evidence ?? "from-element moved")"
        }
        return "dragged \(route)\(tag) — events dispatched; no observable move "
            + "(effect unverified)"
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

    // MARK: - scroll

    @MainActor
    static func runScroll(_ rest: [String]) {
        // Flags in any order: `--visible` (REUSE PixelFlags) and `--in <name>`
        // (consumes the next token). The remaining positionals are
        // <app> <direction> [amount].
        let (mode, afterVisible) = PixelFlags.parse(rest)
        var container: String?
        var pos: [String] = []
        var i = 0
        while i < afterVisible.count {
            if afterVisible[i] == "--in", i + 1 < afterVisible.count {
                container = afterVisible[i + 1]
                i += 2
            } else {
                pos.append(afterVisible[i])
                i += 1
            }
        }
        guard pos.count >= 2 else { usage() }
        let appSpec = pos[0]
        let rawDir = pos[1]
        let rawAmount = pos.count >= 3 ? pos[2] : nil

        let parsed: ScrollSpec.Parsed
        do {
            parsed = try ScrollSpec.parse(direction: rawDir, amount: rawAmount)
        } catch let err as ScrollSpec.ParseError {
            // A bad direction / amount is a USAGE error (exit 2), mirroring the
            // unknown-key / unknown-action wiring.
            let msg: String
            switch err {
            case let .badDirection(d):
                msg = "unknown direction \(d.debugDescription) — use one of "
                    + "\(ScrollSpec.Direction.known)"
            case let .badAmount(a):
                msg = "invalid amount \(a.debugDescription) — expected a positive number (pages)"
            }
            FileHandle.standardError.write(Data("scroll failed: \(msg)\n".utf8))
            exit(2)
        } catch {
            failUnexpected("scroll")
        }

        do {
            let outcome = try GhostHands.scroll(appSpec: appSpec, direction: parsed.direction,
                                                amount: parsed.amount, container: container,
                                                mode: mode)
            print(reportScroll(outcome))
        } catch let error as GhostHandsError {
            fail("scroll", error)
        } catch {
            failUnexpected("scroll")
        }
    }

    /// Honest one-liner for a scroll. VERIFIED quotes the observed scroll-bar
    /// position before → after; DISPATCHED-UNVERIFIED states plainly that the
    /// scroll was dispatched but the bar did not move (already at the boundary) or
    /// could not be observed (no readable scroll bar) — exit 0, NEVER a success
    /// claim. The `.visible` HID path is LABELLED so a non-invisible wheel is never
    /// silent.
    static func reportScroll(_ o: ScrollOutcome) -> String {
        let tag = o.mode == .visible
            ? " [visible HID — wheel posted via .cghidEventTap to the window under the point]"
            : ""
        let where_ = "\(o.direction.rawValue) in \(o.container) (\(o.app))\(tag)"
        if o.verified {
            let b = o.positionBefore.map { String(format: "%.2f", $0) } ?? "?"
            let a = o.positionAfter.map { String(format: "%.2f", $0) } ?? "?"
            return "scrolled \(where_) via \(o.via) — verified: position \(b) → \(a)"
        }
        if !o.observable {
            return "scrolled \(where_) via \(o.via) — event dispatched; no readable "
                + "scroll-bar value to confirm a move (effect unverified)"
        }
        let at = o.positionAfter.map { String(format: "%.2f", $0) } ?? "?"
        return "scrolled \(where_) via \(o.via) — event dispatched; scroll position "
            + "unchanged (\(at) — already at the boundary?) (effect unverified)"
    }

    // MARK: - dialog (detect | respond)

    @MainActor
    static func runDialog(_ rest: [String]) {
        // `dialog <app>` detects; `dialog <app> --click "<button>"` responds. The
        // `--click <button>` flag may appear in any order (mirrors the other flag
        // loops); the first leftover positional is the app spec.
        var appSpec: String?
        var button: String?
        var i = 0
        while i < rest.count {
            if rest[i] == "--click", i + 1 < rest.count {
                button = rest[i + 1]
                i += 2
            } else {
                if appSpec == nil { appSpec = rest[i] }
                i += 1
            }
        }
        guard let appSpec else { usage() }

        do {
            if let button {
                let outcome = try GhostHands.dialogClick(button: button, appSpec: appSpec)
                print(reportDialogClick(outcome))
            } else {
                let report = try GhostHands.dialog(appSpec: appSpec)
                printDialogReport(report)
            }
        } catch let error as GhostHandsError {
            fail("dialog", error)
        } catch {
            failUnexpected("dialog")
        }
    }

    /// Print a DETECT report: the dialog's title, its message lines, and the list
    /// of button names (with a (disabled) flag). The button list goes to stdout
    /// (the actionable payload); the title/message context goes to stderr so a
    /// caller can grab the choices cleanly. An empty message/button set is shown
    /// honestly, never padded.
    static func printDialogReport(_ r: DialogReport) {
        let title = r.title?.isEmpty == false ? r.title! : "(untitled dialog)"
        var header = "dialog in \(r.app): \(title)"
        if !r.messageLines.isEmpty {
            header += "\n" + r.messageLines.map { "  " + $0 }.joined(separator: "\n")
        }
        FileHandle.standardError.write(Data((header + "\n").utf8))
        if r.buttons.isEmpty {
            FileHandle.standardError.write(
                Data("— dialog has no buttons (nothing to respond with)\n".utf8))
        } else {
            for b in r.buttons {
                let flag = b.enabled ? "" : " (disabled)"
                print(b.name + flag)
            }
            let footer = "— \(r.buttons.count) button(s); respond with: "
                + "ghosthands dialog \(r.app.debugDescription) --click \"<button>\"\n"
            FileHandle.standardError.write(Data(footer.utf8))
        }
    }

    /// Honest one-liner for a `dialog --click`. VERIFIED quotes the observed
    /// dismissal (no modal present after the press); DISPATCHED-UNVERIFIED states
    /// plainly that AXPress was accepted but the dialog is still present / the
    /// dismissal was not observed (exit 0, never a faked dismissal).
    static func reportDialogClick(_ o: DialogClickOutcome) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            return "pressed \(o.button.debugDescription) \(where_) — "
                + "verified: \(o.evidence ?? "dialog dismissed")"
        }
        return "pressed \(o.button.debugDescription) \(where_) — AXPress accepted; "
            + "dialog still present (dismissal unverified)"
    }

    // MARK: - key

    @MainActor
    static func runKey(_ rest: [String]) {
        // `--visible` may appear in any order (REUSE PixelFlags); the rest are
        // positional: <spec> [app]. The app spec is OPTIONAL — with no app we post
        // through the HID tap to the frontmost (focused) app.
        let (mode, pos) = PixelFlags.parse(rest)
        guard let spec = pos.first else { usage() }
        let appSpec = pos.count >= 2 ? pos[1] : nil
        do {
            let outcome = try GhostHands.key(spec: spec, appSpec: appSpec, mode: mode)
            print(reportKey(outcome))
        } catch let error as GhostHandsError {
            // An unknown key name is a USAGE error (exit 2), mirroring runAct's
            // `.unknownAction` wiring; a bad spec is likewise a usage error.
            if case .unknownKey = error {
                FileHandle.standardError.write(Data("key failed: \(error)\n".utf8))
                exit(2)
            }
            if case .badKeySpec = error {
                FileHandle.standardError.write(Data("key failed: \(error)\n".utf8))
                exit(2)
            }
            fail("key", error)
        } catch {
            failUnexpected("key")
        }
    }

    /// Honest one-liner for a key dispatch — ALWAYS dispatched-unverified (a key
    /// has no built-in observable; the effect lands wherever the app routes it).
    /// Never claims VERIFIED. The `.visible` HID path is LABELLED so a focus steal
    /// is never silent.
    static func reportKey(_ o: KeyOutcome) -> String {
        // Mirror reportPixel: keep the MECHANISM out of the base (it is never the
        // same in both modes) and move it into the per-mode tag. The base only
        // states the honest verdict — dispatched, effect unverified — which holds
        // for both the per-pid post and the HID post.
        let base = "posted \(o.spec.debugDescription) to \(o.app) — key event "
            + "dispatched; effect unverified"
        if o.mode == .visible {
            // The labelled exception: posted through the HID tap to the FOCUSED
            // app (the caller activated it first when there was one). Do NOT claim
            // the invisible per-pid mechanism here.
            return base + " [visible HID — posted via .cghidEventTap to the "
                + "focused app, may steal focus]"
        }
        // DEFAULT invisible path: per-pid post; honest that macOS may not deliver
        // a key to a non-focused / background app (the same OS wall the pixel
        // per-pid post hits).
        return base + " [invisible — CGEventPostToPid to the app's pid; macOS may "
            + "not deliver to a non-focused / background app]"
    }

    // MARK: - clipboard (read | write)

    @MainActor
    static func runClipboard(_ rest: [String]) {
        guard let sub = rest.first else { usage() }
        let tail = Array(rest.dropFirst())
        switch sub {
        case "read": runClipboardRead(tail)
        case "write": runClipboardWrite(tail)
        default: usage()
        }
    }

    /// `clipboard read` — print the live pasteboard string verbatim. An empty /
    /// absent string is NEVER fabricated: print nothing + an honest stderr note,
    /// exit 0 (a blank clipboard is a real state, not a failure).
    @MainActor
    static func runClipboardRead(_ rest: [String]) {
        let value = GhostHands.clipboardRead()
        if let value, !value.isEmpty {
            print(value)
        } else {
            FileHandle.standardError.write(Data("(clipboard empty / no text)\n".utf8))
        }
        // exit 0 (default) — reading a blank clipboard is not a failure.
    }

    /// `clipboard write <text>` — set the pasteboard, READ IT BACK, and report
    /// honestly: VERIFIED only when the read-back equals the text, else
    /// dispatched-unverified (the set was accepted but not observed — NEVER faked).
    @MainActor
    static func runClipboardWrite(_ rest: [String]) {
        guard let text = rest.first else { usage() }
        let outcome = GhostHands.clipboardWrite(text: text)
        print(reportClipboard(outcome))
        // exit 0 in both verdicts: a dispatched-unverified set is honest, not an
        // error (mirrors set-value / key) — never a nonzero "failure" for a write
        // AppKit accepted but we could not observe.
    }

    /// Honest one-liner for a clipboard write. VERIFIED quotes the read-back length
    /// ("clipboard set, read back N chars"); DISPATCHED-UNVERIFIED states plainly
    /// that AppKit accepted the set but the read-back differs / is absent (the word
    /// 'unverified' is present) — exit 0, never a success claim.
    static func reportClipboard(_ o: ClipboardOutcome) -> String {
        if o.verified {
            // The empty string is indistinguishable from "no text" to `clipboard
            // read` (which collapses "" and nil into the "(clipboard empty / no
            // text)" note). So an empty-intended write that reads back empty MUST
            // be reported as a CLEAR — not "verified: read-back matches" — so the
            // two halves agree on what "empty" means and never make contradictory
            // honest claims about one unchanged pasteboard.
            if o.intended.isEmpty && (o.readback ?? "").isEmpty {
                return "clipboard cleared / now empty"
            }
            return "clipboard set, read back \(o.intended.count) chars — "
                + "verified: read-back matches"
        }
        let was = o.readback.map { "read back \($0.count) chars" } ?? "read back empty"
        return "clipboard set \(o.intended.count) chars via NSPasteboard — set accepted; "
            + "\(was) (effect unverified)"
    }

    // MARK: - install

    @MainActor
    static func runInstall(_ rest: [String]) async {
        // Accept flags in any order (like snapshot/PixelFlags): --force (bool),
        // --dest <dir> (consumes the next token), first leftover positional = dmg.
        var dmgPath: String?
        var dest: String?
        var force = false
        var i = 0
        while i < rest.count {
            let arg = rest[i]
            switch arg {
            case "--force":
                force = true
            case "--dest":
                // consume the next token as the destination directory
                if i + 1 < rest.count {
                    dest = rest[i + 1]
                    i += 1
                }
            default:
                if dmgPath == nil { dmgPath = arg }
            }
            i += 1
        }
        guard let dmgPath else { usage() }
        do {
            let outcome = try await GhostHands.install(dmgPath: dmgPath, dest: dest, force: force)
            print(reportInstall(outcome))
        } catch let error as GhostHandsError {
            fail("install", error)
        } catch {
            failUnexpected("install")
        }
    }

    /// Honest one-liner for an install. VERIFIED names the bundle, the dest, and
    /// quotes the proven CFBundleIdentifier as evidence; DISPATCHED-UNVERIFIED
    /// states plainly that `cp` returned 0 but the bundle could not be confirmed
    /// (the word "unverified" is present) — exits 0, NEVER a success/installed
    /// claim on a copy that wasn't verified.
    static func reportInstall(_ o: GhostHands.InstallOutcome) -> String {
        if o.verified {
            let id = o.bundleIdentifier ?? "?"
            return "installed \(o.appName.debugDescription) to \(o.dest) — "
                + "verified: CFBundleIdentifier \(id) present"
        }
        return "copied \(o.appName.debugDescription) to \(o.dest) — cp returned 0; "
            + "could not confirm bundle (effect unverified)"
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
          ghosthands click "<name>" <app> [--role <AXRole>] [--text <substr>] [--nth <i>]   press a named control (AX, cursor-less)
          ghosthands type "<text>" "<field>" <app>    set a text field's value, then read it back
          ghosthands set-value "<v>" "<ctl>" <app>    set a checkbox/slider/popup, then read it back
          ghosthands doubleclick "<name>" <app>       open a row/file (AXOpen), verified by effect
          ghosthands right-click "<name>" <app> [--visible]   open an element's context menu (AXShowMenu, else pixel right-click), verified by menu-appeared
          ghosthands act <action> "<name>" <app>      invoke a named AX action (see actions below)
          ghosthands focus "<name>" <app>             give a control keyboard focus (AXFocused), verified by read-back
          ghosthands snapshot <app> [--ax|--json]     dump the AX tree (pure read, default --ax)
          ghosthands extract <app> [--in <name>]      extract a table/outline/list as TSV rows (pure read)
          ghosthands web read <browser> [--cdp|--ax] [--debug-port N] [--relaunch]   page digest (auto: CDP when a debug port is open, else AX)
          ghosthands web tabs <browser> [--cdp|--ax] [--debug-port N] [--relaunch]   list open tabs (CDP lists background tabs too; AX marks * selected)
          ghosthands web click "<selector>" <browser> [--cdp|--debug-port N] [--relaunch]        click a CSS-selected element (CDP-only), verified by navigation
          ghosthands web fill "<selector>" "<text>" <browser> [--cdp|--debug-port N] [--relaunch] set a CSS-selected input's value (CDP-only), verified by read-back
          ghosthands web html "<selector>" <browser> [--cdp|--debug-port N] [--relaunch]         dump a CSS-selected element's outerHTML + attrs + computed style (CDP-only read)
          ghosthands web eval "<js>" <browser> [--cdp|--debug-port N] [--relaunch]               evaluate a JS expression and print the returned value (CDP-only power tool)
          (--relaunch: opt-in. When the debug port is CLOSED, launch a NEW, ISOLATED throwaway browser
           instance — ephemeral OS-chosen port + a fresh temp profile (never your real cookies/history).
           Without it, a closed port still refuses. Never relaunches silently, never touches your profile.)
          ghosthands navigate "<url>" [browser]       load a URL in a browser, verify by reading the page URL back
          ghosthands windows <app>                    list windows (id, title, frame, display, flags) — pure read
          ghosthands window move <x> <y> <app> [--window <id|title>]    set position (invisible AX set), verified by read-back
          ghosthands window resize <w> <h> <app> [--window <id|title>]  set size (invisible AX set), verified by read-back
          ghosthands window raise <app> [--window <id|title>]          AXRaise (stacking only) — dispatched-unverified
          ghosthands find "<name>" <app>              does a named element exist? (exit 0/1)
          ghosthands wait "<name>" <app> [--gone] [--timeout <s>] [--interval <ms>]   poll until a named element appears (or --gone: disappears); refuses on timeout
          ghosthands shot <app> <out.png>             honest screenshot (refuses without Screen Recording)
          ghosthands click-at <x> <y> <app> [--visible]           left click at a GLOBAL screen point (pixel, verify-by-diff)
          ghosthands drag <x1> <y1> <x2> <y2> <app> [--visible]   press-move-release between two GLOBAL points (pixel)
          ghosthands drag "<from>" "<to>" <app> [--visible]       drag one named element onto another (centers), verified by from-element move/vanish
          ghosthands scroll <app> <up|down|left|right> [amount] [--in <name>] [--visible]   scroll a list/scroll-area, verified by the scroll-bar position
          ghosthands dialog <app>                     detect the frontmost modal sheet/alert/dialog: print its title/message + button names (refuses if none)
          ghosthands dialog <app> --click "<button>"  press a button WITHIN the detected dialog, verified by the dialog being dismissed
          ghosthands key "<spec>" [app] [--visible]               post a keystroke/chord (e.g. return, cmd+s) — dispatched-unverified
          ghosthands clipboard read                   print the current pasteboard string (UTF-8); empty → honest note, exit 0
          ghosthands clipboard write "<text>"         set the pasteboard string, then READ IT BACK — verified by read-back
          ghosthands install <dmg-path> [--force] [--dest <dir>]  install a .app from a DMG via cp -R (default dest /Applications)
          ghosthands replay <flow.json> [--keep-going] run a recorded flow in order (stops on refuse)
          ghosthands record <flow.json> <verb> <args> run a verb AND append it to the flow if it didn't refuse
          ghosthands version

          <action> for `act` = open | confirm | pick | show-menu | cancel | raise | increment | decrement

        <app> = bundle id, pid, or (partial) app name. Examples:
          ghosthands click "New Folder" Finder
          ghosthands click "Delete" Mail --role AXButton          (one role narrows the ambiguity)
          ghosthands click "Add" "System Settings" --nth 1        (pick the 2nd of several "Add" controls)
          ghosthands click "Tab" Safari --text "Inbox" --nth 0    (filter by label substring, then pin)
          ghosthands type "hello" "Search" Safari
          ghosthands set-value "on" "Wi-Fi" "System Settings"
          ghosthands doubleclick "report.pdf" Finder
          ghosthands right-click "report.pdf" Finder
          ghosthands act increment "Volume" "System Settings"
          ghosthands focus "Search" Safari
          ghosthands snapshot Calculator --json
          ghosthands extract "System Information"
          ghosthands extract Mail --in "Messages"
          ghosthands web read Brave
          ghosthands web tabs Chrome
          ghosthands web click "#submit" Brave
          ghosthands web fill "input[name=q]" "swift" Chrome
          ghosthands web html "#submit" Brave
          ghosthands web eval "document.title" Chrome
          ghosthands navigate "example.com" Brave
          ghosthands navigate "https://docs.swift.org/"
          ghosthands windows Finder
          ghosthands window move 100 80 Calculator
          ghosthands window resize 800 600 Notes --window "Untitled"
          ghosthands window raise Preview --window 12345
          ghosthands find "7" Calculator
          ghosthands wait "Save" TextEdit
          ghosthands wait "Spinner" Safari --gone --timeout 10
          ghosthands wait "Login" MyApp --timeout 8 --interval 250
          ghosthands shot Calculator /tmp/calc.png
          ghosthands click-at 480 300 Calculator
          ghosthands drag 100 200 400 200 Preview
          ghosthands scroll Safari down
          ghosthands scroll System\\ Settings down 2 --in "Sidebar"
          ghosthands dialog TextEdit
          ghosthands dialog TextEdit --click "Don't Save"
          ghosthands key return Safari
          ghosthands key "cmd+shift+t" Chrome
          ghosthands key return                 (no app — posts to the frontmost app)
          ghosthands clipboard read
          ghosthands clipboard write "hello world"
          ghosthands install ~/Downloads/Foo.dmg
          ghosthands install ~/Downloads/Foo.dmg --dest ~/Applications --force
          ghosthands record /tmp/login.json type "alice" "Username" Safari
          ghosthands replay /tmp/login.json

          Locator disambiguators (OPT-IN; click/type/set-value/act/focus/right-click/doubleclick):
            --role <AXRole>  keep only candidates of this AX role (e.g. --role AXButton)
            --text <substr>  keep only candidates whose label/value contains <substr>
            --nth <i>        pick the i-th match (0-based, deterministic tree order)
            With NO flag the behavior is UNCHANGED — a name matching >1 distinct control
            still REFUSES (ambiguous). --role/--text only NARROW the set (an ambiguous
            remainder is still refused); --nth is the EXPLICIT tie-break (out of range
            REFUSES — never a silent guess). The caller states intent; the tool never picks.
            Note: --nth indexes the RAW survivors (duplicate-render twins NOT collapsed),
            so its valid indices can outnumber the "ambiguous — K controls" count, and the
            index is a snapshot — a re-snapshot after a UI change can renumber it.

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
          - focus sets AXFocused = true on the named control then RE-READS AXFocused off a
            fresh tree: VERIFIED only when it reads back true; an AX-accepted set whose
            AXFocused reads back false — or whose AXFocused is unreadable/unsettable on that
            control — is dispatched-unverified, NEVER a focus claim. type AUTO-FOCUSES the
            field before writing (best-effort, so a later Enter lands), but type's verdict
            still comes from the value read-back, never from focus.
          - right-click opens an element's CONTEXT MENU, in honesty order: it RESOLVES the
            named element (same refuse-on-not-found / refuse-on-ambiguous rules as click);
            prefers the AX route (if the element advertises AXShowMenu, performs it —
            invisible, cursor-less); else falls back to a REAL right-click (CGEvent
            rightMouseDown + rightMouseUp) at the element CENTER (invisible CGEventPostToPid
            by default, or --visible HID — which moves the cursor and may steal focus). It
            WITNESSES by counting context AXMenu elements in the app's AX tree before vs
            after: a NEW menu appeared → VERIFIED (works for BOTH routes, incl. the pixel
            one); the action landed but no menu was observed → dispatched-unverified, NEVER a
            faked success. It REFUSES a pixel-route element with no readable AX frame (no
            point to aim at) rather than poke a guessed location.
          - navigate loads <url> via `open -a <browser> <url>` (no cursor, no focus games
            beyond what the load surfaces), settles, then RE-READS the FOCUSED window's
            page AXWebArea URL/title (the window `open` raised the load into — NOT the
            first-enumerated window, so a pre-existing same-host tab can't be mistaken for
            this load): VERIFIED only when the landed host matches the requested host (and
            the path when a specific one was requested); a load whose page can't be read
            back, or whose host doesn't (yet) match — an SPA client-side route, a
            redirect/SSO we can't confirm, or an AXWebArea that isn't exposed — is reported
            dispatched-unverified, NEVER "navigated". "open returned 0" is NOT proof. It
            REFUSES a malformed URL (no host after normalizing) and an unresolved/ambiguous
            browser; with [browser] omitted it auto-picks the first RUNNING Chromium
            (Brave → Chrome → Chromium → Arc → Edge) and refuses if none is running rather
            than fall back to a browser it cannot verify against. v1 = open + read-back;
            typing the URL into the omnibox is a future upgrade.
          - web click / web fill are the CDP-only DOM-selector ACTUATION tier — a CSS
            selector has no AX equivalent, so they REQUIRE CDP (default --cdp, port 9222;
            a forced --ax REFUSES with a usage error). web click runs ONE occlusion probe
            (document.elementFromPoint at the target's center): a missing selector REFUSES
            (selectorNotFound), an OVERLAID target REFUSES (elementCovered — never click
            through another element), else it dispatches a TRUSTED Input.dispatchMouseEvent
            and verifies by an href change: a navigation is VERIFIED, an unchanged URL is
            dispatched-unverified (the click landed; its in-page effect is unproven), NEVER
            success. web fill focuses the input, sets .value, fires input+change, then READS
            the value back: readback == text is VERIFIED, anything else is dispatched-
            unverified (a field that rejects/caps/transforms the set is NEVER success). A
            SECURE (password) input is REFUSED — its value can't be read back to verify.
          - web html / web eval are CDP-only READ verbs (a CSS selector / a JS expression
            has no AX equivalent; a forced --ax REFUSES). web html dumps, for the FIRST
            element a selector resolves to, exactly what the DOM exposes: its outerHTML
            (sliced to 20000 chars, truncation flagged), every attribute name→value, and a
            CURATED computed-style subset (display/visibility/position/color/background/
            font-size/width/height) — a missing selector REFUSES (selectorNotFound), never
            an empty shell; a prop the page didn't return reads '(not reported)', never
            fabricated. web eval Runtime.evaluates the expression (returnByValue,
            awaitPromise) and prints the value; a page-side THROW is surfaced as a CDP
            transport error carrying the exception text, NEVER a fake empty success.
          - windows is a pure read (no focus steal, no AXRaise); a nil window id/title/
            display is reported as unknown ('?' / off-screen), never fabricated.
          - window move/resize set an AX attribute INVISIBLY (cursor-less, no focus steal,
            no app activation) then RE-READ position/size: VERIFIED only when the read-back
            lands within tolerance of the target; if the OS CLAMPS it (min size, off-screen
            guard, full-screen/zoomed windows that ignore the set) the ACTUAL landed frame is
            reported as dispatched (honest, never a fake verified, never a refuse); an
            AX-accepted-but-unchanged set is dispatched-unverified.
          - window raise is AXRaise — a STACKING change only. z-order has no AX read-back, so
            it is ALWAYS dispatched-unverified; it does NOT activate the app or steal focus
            (we use the raw raise, not focusWindow/showWindow). A rejected raise REFUSES.
          - window move/resize/raise REFUSE when the app has >1 window and no --window
            selector (mirroring click's ambiguous refuse), rather than mutate window[0].
          - extract reads ONE tabular container (an AXTable/AXOutline/AXList) into clean
            TSV rows — header first when the table advertises AXColumns with titles. It
            resolves a NAMED container (--in <name>, refusing on an ambiguous match like
            click) else the FIRST/primary table in the frontmost window, and REFUSES
            (noTabularData) when none is found. HONESTY: it emits ONLY the cell values AX
            exposes — a cell with no readable value is BLANK, never guessed — and a
            present-but-EMPTY table (0 AXRow children) is honest EMPTY output (0 rows),
            distinct from a MISSING table (a refuse). It is a pure read: no press, no
            focus steal.
          - wait polls Finder.resolve for a named element on a real wall-clock DEADLINE
            loop (the testing backbone — a real condition wait, not a magic sleep). Without
            --gone it succeeds the instant the element EXISTS; with --gone the instant it is
            ABSENT. Between checks it sleeps a bounded --interval (the poll CADENCE, default
            150ms, NOT a fixed guess at the work's duration), and the hard --timeout (default
            5s) is the real bound. It reports the OBSERVED elapsed time + poll count. A
            timeout is a REFUSE (nonzero exit), NEVER a fabricated success: met is reported
            ONLY when the condition is observed met. App resolution is inside the loop, so a
            not-yet-running app is a not-yet poll (it waits for the app to appear too), not an
            instant miss; a bad --timeout/--interval is a usage error (exit 2) before spinning.
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
          - key posts a keystroke/chord (the base key is the LAST '+'-token; earlier
            tokens are modifiers cmd|shift|alt|ctrl). It REFUSES (exit 2) on an unknown
            key name or a bad spec, BEFORE posting anything. A key event has NO built-in
            observable (no AX value, and no caller-supplied point to screenshot-diff), so
            it is ALWAYS dispatched-unverified in BOTH modes — like window raise, never a
            faked verified. Two delivery modes (the INVISIBILITY axis):
              default (invisible best-effort, REQUIRES an app): post the key straight to
                the app's pid (CGEventPostToPid) — cursor-less, no focus steal,
                background-capable. But postToPid is delivery-only: macOS may NOT route a
                key to a non-focused / background app (the same OS wall the pixel postToPid
                hits), so we NEVER promise background key delivery.
              --visible (LABELLED exception): activate the app to take focus, then post a
                real HID keystroke via the .cghidEventTap so the focused app receives it
                like a real keypress (the path for when the invisible post does not land).
                NOT invisible — may FOREGROUND / steal focus, and the key goes to whatever
                app is focused (an OS wall). With NO app spec, key uses this HID path on
                the FRONTMOST app (there is no pid to post to).
          - clipboard read prints the live NSPasteboard string verbatim (UTF-8); an
            empty / absent string is NEVER fabricated — it prints nothing + an honest
            stderr note "(clipboard empty / no text)" and exits 0 (a blank clipboard is
            a real state). clipboard write sets the pasteboard string then READS IT BACK
            off the live pasteboard: read-back == text ⇒ VERIFIED ("clipboard set, read
            back N chars"); read-back != text (another process clobbered it, or a
            pasteboard owner transformed/cleared it) ⇒ dispatched-unverified — the set
            was accepted but not observed, NEVER a faked success. The NSPasteboard
            setString boolean is never trusted; the read-back is the sole arbiter.
          - scroll scrolls a scroll-area / list and VERIFIES by the scroll-bar position.
            It resolves a container (--in <name> = a named AXScrollArea; else the focused
            element's enclosing scroll area; else the largest AXScrollArea in the frontmost
            window) and REFUSES (.noScrollArea) if none is scrollable. It reads the relevant
            scroll bar's AXValue (0.0 top/left … 1.0 bottom/right) BEFORE acting, actuates —
            preferring a cursor-less AX scroll-bar SET when the bar is settable, else a CGEvent
            scrollWheel (invisible CGEventPostToPid by default; --visible posts via the HID tap
            so the WindowServer routes the wheel to the window under the point, NOT invisible) —
            then RE-READS the bar: position MOVED ⇒ VERIFIED (quotes before → after); UNCHANGED
            ⇒ dispatched-unverified — a scroll already pinned at the boundary that cannot move,
            or a list with no readable scroll bar, is honestly DISPATCHED, NEVER a fake success.
            [amount] is a positive page count (default 1 page); a bad direction/amount REFUSES
            (exit 2) before acting.
          - drag "<from>" "<to>" <app> is the ELEMENT form of drag (told apart from the
            pixel form by ARITY: exactly 3 positionals — a pixel drag needs 5, so the
            names may themselves be numeric, e.g. drag "5" "7" Calculator). It RESOLVES both named elements
            (same refuse-on-not-found / refuse-on-ambiguous rules as click, over the openable
            gate — rows/cells/files/controls), aims at each element's CENTER, and posts a
            pixel drag (mouse-down at from-center, interpolated drags to to-center, mouse-up
            at to-center) via the SAME posting helpers as the pixel verbs (invisible
            CGEventPostToPid by default; --visible warps the real cursor + HID tap, NOT
            invisible, may steal focus). It REFUSES (.noElementFrame) if EITHER element exposes
            no readable AX frame to aim at. A pixel drag has NO self-signal, so it WITNESSES by
            re-resolving the FROM-element off a fresh tree and comparing its frame: the
            from-element's center MOVED past a small floor, or it VANISHED ⇒ VERIFIED (quotes
            before → after); still at the same center, or its frame unreadable on read-back ⇒
            dispatched-unverified — events sent, no observable move, NEVER a faked success. The
            witness only under-claims (a drop that does not relocate the source reads as
            dispatched), never a false verified.
          - install mounts the DMG (hdiutil), finds the SINGLE top-level .app, and
            copies it with cp -R (no GUI drag — no cursor, no focus steal), then
            ALWAYS detaches the mount. It REFUSES (nothing copied) on a missing DMG,
            a mount failure, zero or >1 .app in the DMG, or a destination that
            already holds <App>.app without --force (it will not clobber an
            installed app). It reports VERIFIED only when the installed bundle is
            present AND its Contents/Info.plist parses with a CFBundleIdentifier;
            a cp that returns 0 but cannot be confirmed is dispatched-unverified,
            NEVER "installed". It does NOT verify Gatekeeper/quarantine/notarization,
            code-signature validity, or first-launch TCC — presence + Info.plist only.
          - dialog DETECTS the frontmost modal sheet / alert / dialog in the app (an
            AXSheet, or a window whose SUBROLE is AXDialog/AXSystemDialog) via a
            BOUNDED AX walk (depth cap + visited-set — a cyclic tree never overflows),
            and prints its title, its static-text message lines, and the names of its
            BUTTONS. It REFUSES (.noDialog) when no modal is present — never fabricates
            a popup. `dialog <app> --click "<button>"` RESPONDS: it re-detects the
            modal, resolves the named button SCOPED TO THE DIALOG node (same refuse-on-
            not-found / refuse-on-ambiguous rules as click, so a same-named button on a
            background window is never pressed), AXPresses it, then WITNESSES by a fresh
            read: a modal dialog GONE ⇒ VERIFIED (dismissed); a modal STILL PRESENT ⇒
            dispatched-unverified — the press landed but the dialog did not go away (a
            validation block, or a follow-up modal), NEVER a faked dismissal. A button
            that rejects AXPress REFUSES (.actionRejected).
        """
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }
}
