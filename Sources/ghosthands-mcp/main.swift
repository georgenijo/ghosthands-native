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
        do {
            switch name {
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
            default:
                return MCPMapping.usageError("unknown tool: \(name)")
            }
        } catch let error as GhostHandsError {
            // A REFUSE → isError:true tool result with the honest one-liner.
            return MCPMapping.refuse(error)
        } catch {
            // A non-GhostHands error → isError:true so the model still sees it.
            // Keep the client text terse, but log the REAL cause to stderr (a
            // non-protocol channel) so a crash is diagnosable instead of vanishing.
            log("\(name) failed: \(error)")
            return MCPMapping.usageError("\(name) failed: unexpected error")
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
