import Foundation
import GhostHandsKit

/// `ghosthands-mcp` — the GhostHands hands+eyes exposed over the Model Context
/// Protocol so ANY external brain (a local model, Claude, a phone agent) can
/// drive this Mac. No brain here; just the verbs.
///
/// TRANSPORT: MCP over STDIO, JSON-RPC 2.0, NEWLINE-DELIMITED framing — one
/// compact JSON object per line, `\n`-terminated. Protocol JSON goes to stdout
/// ONLY; all diagnostics go to stderr (so the framing is never corrupted).
///
/// The protocol routing, schemas, and the verified/dispatched-unverified/refuse
/// honesty mapping all live in PURE, hermetically-tested code in GhostHandsKit
/// (`MCPProtocol`, `MCPTools`, `MCPMapping`). This file is just the I/O loop +
/// the async/AX verb dispatch the pure layer cannot do.
@main
struct GhostHandsMCP {
    @MainActor
    static func main() async {
        log("ghosthands-mcp \(GhostHands.version) — MCP/stdio (newline-delimited JSON-RPC)")
        let input = FileHandle.standardInput
        var buffer = Data()

        while true {
            // Block for the next chunk of stdin. EOF (empty Data) ends the loop.
            let chunk = input.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { break }
                // Flush a trailing line with no terminating newline.
                await handleLine(drain(&buffer))
                break
            }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self)
                await handleLine(line)
            }
        }
    }

    /// Pull the remaining buffer out as a String (used for an unterminated tail).
    static func drain(_ buffer: inout Data) -> String {
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Decode → route → (maybe) dispatch → write one response line.
    @MainActor
    static func handleLine(_ line: String) async {
        guard let value = JSONRPCFraming.decodeLine(line) else {
            // Blank line: nothing to do. Non-blank but unparseable: parse error.
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                write(JSONRPCResponse.error(
                    id: .null, code: JSONRPCError.parse, message: "parse error"))
            }
            return
        }

        switch MCPProtocol.route(value) {
        case .ignore:
            return
        case let .respond(response):
            write(response)
        case let .dispatchTool(id, name, arguments):
            let result = await dispatch(name: name, arguments: arguments)
            write(JSONRPCResponse.success(id: id, result: result))
        }
    }

    /// Run the named verb on the @MainActor and map its Outcome (or thrown
    /// GhostHandsError) to an MCP tool result via the PURE mapping. Required-arg
    /// presence was already validated by `MCPProtocol`; we force-read here.
    @MainActor
    static func dispatch(name: String, arguments: JSONValue) async -> JSONValue {
        func arg(_ k: String) -> String { MCPProtocol.string(k, from: arguments) ?? "" }
        func optStr(_ k: String) -> String? { MCPProtocol.string(k, from: arguments) }
        func num(_ k: String) -> Double? { MCPProtocol.number(k, from: arguments) }
        func flag(_ k: String) -> Bool { MCPProtocol.bool(k, from: arguments) }

        // The opt-in defaults MIRROR the CLI exactly: invisible unless `visible`,
        // the `auto` web lens unless `cdp`/`ax`, port 9222, relaunch OFF.
        let mode: PixelMode = flag("visible") ? .visible : .invisible
        let locator = LocatorSpec(role: optStr("role"), text: optStr("text"),
                                  nth: MCPProtocol.int("nth", from: arguments))
        let lens: WebLens = flag("cdp") ? .cdp : (flag("ax") ? .ax : .auto)
        let port = MCPProtocol.int("debugPort", from: arguments) ?? 9222
        let relaunch = flag("relaunch")
        let windowSel = optStr("window").map { WindowSelector.parse($0) }
        // `target` picks WHICH CDP page/renderer to drive (multi-window Electron):
        // an integer index or a title/url substring. Omitted → first debuggable page.
        let pick = optStr("target").map { CDPTargetPick.parse($0) }

        do {
            switch name {
            // MARK: existing 8 verbs — UNCHANGED honesty mapping (per-Outcome).
            case "click":
                let o = try GhostHands.click(name: arg("name"), appSpec: arg("app"))
                return MCPMapping.map(o)
            case "type":
                let o = try GhostHands.type(text: arg("text"), field: arg("field"),
                                            appSpec: arg("app"))
                return MCPMapping.map(o)
            case "set_value":
                let o = try GhostHands.setValue(value: arg("value"), control: arg("control"),
                                                appSpec: arg("app"))
                return MCPMapping.map(o)
            case "doubleclick":
                let o = try GhostHands.doubleclick(name: arg("name"), appSpec: arg("app"))
                return MCPMapping.map(o)
            case "act":
                let o = try GhostHands.act(action: arg("action"), name: arg("name"),
                                           appSpec: arg("app"))
                return MCPMapping.map(o)
            case "menu":
                let o = try GhostHands.menu(path: arg("path"), appSpec: arg("app"))
                return MCPMapping.fromEnvelope(.fromMenu(o))
            case "apps":
                return MCPMapping.fromEnvelope(.fromApps(GhostHands.apps()))
            case "ocr":
                let items = try await GhostHands.ocr(appSpec: arg("app"))
                return MCPMapping.fromEnvelope(.fromOCR(items, app: arg("app")))
            case "snapshot":
                let o = try GhostHands.snapshot(appSpec: arg("app"))
                let asJSON = (MCPProtocol.string("format", from: arguments) ?? "ax") == "json"
                return MCPMapping.map(o, asJSON: asJSON)
            case "find":
                let o = try GhostHands.find(query: arg("query"), appSpec: arg("app"))
                return MCPMapping.map(o)
            case "shot":
                let o = try await GhostHands.shot(appSpec: arg("app"), outPath: arg("out_path"))
                return MCPMapping.map(o)

            // MARK: new surface — shaped via the SAME JSONResult.from* envelope.
            case "focus":
                let o = try GhostHands.focus(name: arg("name"), appSpec: arg("app"),
                                             locator: locator)
                return MCPMapping.fromEnvelope(.fromFocus(o))
            case "right_click":
                let o = try GhostHands.rightClick(name: arg("name"), appSpec: arg("app"),
                                                  mode: mode, locator: locator)
                return MCPMapping.fromEnvelope(.fromRightClick(o))
            case "scroll":
                let parsed = try ScrollSpec.parse(
                    direction: arg("direction"),
                    amount: num("amount").map { String($0) })
                let o = try GhostHands.scroll(appSpec: arg("app"), direction: parsed.direction,
                                              amount: parsed.amount, container: optStr("container"),
                                              mode: mode)
                return MCPMapping.fromEnvelope(.fromScroll(o))
            case "drag":
                let o = try GhostHands.dragElement(from: arg("from"), to: arg("to"),
                                                   appSpec: arg("app"), mode: mode)
                return MCPMapping.fromEnvelope(.fromDragElement(o))
            case "extract":
                let r = try GhostHands.extract(appSpec: arg("app"), container: optStr("container"))
                return MCPMapping.fromEnvelope(.fromExtract(r))
            case "dialog":
                if let button = optStr("button"), !button.isEmpty {
                    let o = try GhostHands.dialogClick(button: button, appSpec: arg("app"))
                    return MCPMapping.fromEnvelope(.fromDialogClick(o))
                }
                let r = try GhostHands.dialog(appSpec: arg("app"))
                return MCPMapping.fromEnvelope(.fromDialogReport(r))
            case "wait":
                // CLI parity: pre-validate the deadline as finite/positive (JSON
                // can't carry NaN/Inf, but a 0/negative timeout would otherwise be
                // forwarded). The kit still refuses honestly on a bad deadline, but
                // mirror the CLI's exit-2 usage refuse so the message matches.
                let waitTimeout = num("timeout") ?? 5
                guard waitTimeout.isFinite, waitTimeout > 0 else {
                    return MCPMapping.usageError(
                        "wait: 'timeout' expects a finite number > 0, got \(waitTimeout)")
                }
                let o = try GhostHands.wait(
                    name: arg("name"), appSpec: arg("app"), wantGone: flag("gone"),
                    timeout: waitTimeout,
                    interval: (num("interval") ?? 150) / 1000)
                return MCPMapping.fromEnvelope(.fromWait(o))
            case "assert":
                return try assertResult(arguments: arguments)
            case "clipboard_read":
                return MCPMapping.fromEnvelope(.fromClipboardRead(GhostHands.clipboardRead()))
            case "clipboard_write":
                let o = GhostHands.clipboardWrite(text: arg("text"))
                return MCPMapping.fromEnvelope(.fromClipboard(o))
            case "navigate":
                let o = try GhostHands.navigate(url: arg("url"), browser: optStr("browser"))
                return MCPMapping.fromEnvelope(.fromNavigate(o))
            case "key":
                let o = try GhostHands.key(spec: arg("spec"), appSpec: optStr("app"), mode: mode)
                return MCPMapping.fromEnvelope(.fromKey(o))
            case "install":
                let o = try await GhostHands.install(dmgPath: arg("dmg"), dest: optStr("dest"),
                                                     force: flag("force"))
                return MCPMapping.fromEnvelope(.fromInstall(o))
            case "windows":
                let r = try GhostHands.windows(appSpec: arg("app"))
                return MCPMapping.fromEnvelope(.fromWindows(r))
            case "window_move":
                let o = try GhostHands.windowMove(x: num("x") ?? 0, y: num("y") ?? 0,
                                                  appSpec: arg("app"), selector: windowSel)
                return MCPMapping.fromEnvelope(.fromWindowMutate(o))
            case "window_resize":
                let o = try GhostHands.windowResize(w: num("w") ?? 0, h: num("h") ?? 0,
                                                    appSpec: arg("app"), selector: windowSel)
                return MCPMapping.fromEnvelope(.fromWindowMutate(o))
            case "window_raise":
                let o = try GhostHands.windowRaise(appSpec: arg("app"), selector: windowSel)
                return MCPMapping.fromEnvelope(.fromWindowRaise(o))
            case "web_read":
                let (r, served) = try await GhostHands.webRead(
                    browser: arg("browser"), lens: lens, debugPort: port,
                    relaunch: relaunch, pick: pick)
                return MCPMapping.fromEnvelope(.fromWebRead(r, served: served))
            case "web_tabs":
                let (r, served) = try await GhostHands.webTabs(
                    browser: arg("browser"), lens: lens, debugPort: port, relaunch: relaunch)
                return MCPMapping.fromEnvelope(.fromWebTabs(r, served: served))
            case "web_click":
                let r = try await GhostHands.webClick(
                    selector: arg("selector"), browser: arg("browser"), lens: lens,
                    debugPort: port, relaunch: relaunch, pick: pick)
                return MCPMapping.fromEnvelope(.fromWebActuate(r))
            case "web_fill":
                let r = try await GhostHands.webFill(
                    selector: arg("selector"), text: arg("text"), browser: arg("browser"),
                    lens: lens, debugPort: port, relaunch: relaunch, pick: pick)
                return MCPMapping.fromEnvelope(.fromWebActuate(r))
            case "web_select":
                let r = try await GhostHands.webSelect(
                    selector: arg("selector"), value: arg("value"), browser: arg("browser"),
                    lens: lens, debugPort: port, relaunch: relaunch, pick: pick)
                return MCPMapping.fromEnvelope(.fromWebActuate(r))
            case "web_type":
                let r = try await GhostHands.webType(
                    selector: arg("selector"), text: arg("text"), submit: flag("submit"),
                    browser: arg("browser"), lens: lens, debugPort: port,
                    relaunch: relaunch, pick: pick)
                return MCPMapping.fromEnvelope(.fromWebActuate(r))
            case "web_key":
                let r = try await GhostHands.webKey(
                    chord: arg("chord"), browser: arg("browser"), lens: lens,
                    debugPort: port, relaunch: relaunch, pick: pick)
                return MCPMapping.fromEnvelope(.fromWebKey(r))
            case "web_html":
                let r = try await GhostHands.webHtml(
                    selector: arg("selector"), browser: arg("browser"), lens: lens,
                    debugPort: port, relaunch: relaunch, pick: pick)
                return MCPMapping.fromEnvelope(.fromWebHtml(r))
            case "web_eval":
                let r = try await GhostHands.webEval(
                    js: arg("js"), browser: arg("browser"), lens: lens,
                    debugPort: port, relaunch: relaunch, pick: pick)
                return MCPMapping.fromEnvelope(.fromWebEval(r))

            default:
                return MCPMapping.usageError("unknown tool: \(name)")
            }
        } catch let error as GhostHandsError {
            // A REFUSE → isError:true tool result with the honest one-liner.
            return MCPMapping.refuse(error)
        } catch let error as ScrollSpec.ParseError {
            // A bad scroll direction/amount is a usage refuse → isError (mirrors
            // the CLI exit-2 path), carrying the same honest message.
            return MCPMapping.usageError(scrollParseMessage(error))
        } catch {
            // A non-GhostHands error → isError:true so the model still sees it.
            // Keep the client text terse, but log the REAL cause to stderr (a
            // non-protocol channel) so a crash is diagnosable instead of vanishing.
            log("\(name) failed: \(error)")
            return MCPMapping.usageError("\(name) failed: unexpected error")
        }
    }

    /// `assert` shapes through the SAME pass/fail/refuse split the CLI uses:
    ///   • a CHECKED verdict (PASS or FAIL) → the `JSONResult.fromAssert` envelope
    ///     (isError:false — the assertion was answered honestly).
    ///   • the assertion could NOT be built (bad/missing kind or count) → an
    ///     isError refuse, NEVER a fake pass — the same exit-2 wall the CLI keeps.
    /// A thrown `GhostHandsError` (app/element unreadable) is caught by the outer
    /// `dispatch` and becomes an isError refuse too.
    @MainActor
    static func assertResult(arguments: JSONValue) throws -> JSONValue {
        func arg(_ k: String) -> String { MCPProtocol.string(k, from: arguments) ?? "" }
        let name = arg("name")
        let appSpec = arg("app")
        let expected = MCPProtocol.string("expected", from: arguments)
        let kind: AssertVerdict.Kind
        switch arg("kind") {
        case "exists": kind = .exists
        case "absent": kind = .absent
        case "value":
            guard let expected else {
                return MCPMapping.usageError(
                    "assert value: missing required 'expected' value")
            }
            kind = .valueEquals(expected)
        case "count":
            guard let raw = expected, let n = Int(raw), n >= 0 else {
                return MCPMapping.usageError(
                    "assert count: 'expected' must be a non-negative integer, got "
                        + (expected?.debugDescription ?? "(missing)"))
            }
            kind = .countEquals(n)
        default:
            return MCPMapping.usageError(
                "assert: unknown kind \(arg("kind").debugDescription) — "
                    + "use exists | absent | value | count")
        }
        let o = try GhostHands.assert(kind, name: name, appSpec: appSpec)
        return MCPMapping.fromEnvelope(.fromAssert(o))
    }

    /// The honest one-liner for a scroll-spec parse refuse (mirrors the CLI's
    /// exit-2 messages).
    static func scrollParseMessage(_ err: ScrollSpec.ParseError) -> String {
        switch err {
        case let .badDirection(d):
            return "unknown direction \(d.debugDescription) — use one of "
                + "\(ScrollSpec.Direction.known)"
        case let .badAmount(a):
            return "invalid amount \(a.debugDescription) — expected a positive number (pages)"
        }
    }

    // MARK: - stdio (protocol JSON to stdout, logs to stderr)

    static func write(_ value: JSONValue) {
        let line = JSONRPCFraming.encodeLine(value) + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
