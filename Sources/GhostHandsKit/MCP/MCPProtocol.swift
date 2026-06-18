import Foundation

/// PURE routing for the MCP protocol methods that need no AX/stdio:
/// `initialize`, `notifications/initialized`, `tools/list`, and the front-half
/// of `tools/call` (name + arguments extraction + validation). The actual verb
/// dispatch (which touches AX and is async) is done by the executable; this
/// layer decides everything that can be decided without a live app, so the
/// protocol shape is hermetically testable.
public enum MCPProtocol {
    /// The protocol version this server implements/advertises.
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "ghosthands-mcp"

    /// The decision for one inbound request, as far as the PURE layer can take
    /// it. `.respond` carries a fully-built JSON-RPC response. `.dispatchTool`
    /// means the request is a well-formed `tools/call` whose arguments validated
    /// — the executable must run the verb (async/AX) and build the result.
    /// `.ignore` is a notification (send nothing).
    public enum Decision: Sendable, Equatable {
        case respond(JSONValue)
        case dispatchTool(id: JSONValue?, name: String, arguments: JSONValue)
        case ignore
    }

    /// The initialize result object.
    public static func initializeResult() -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
            ]),
            "serverInfo": .object([
                "name": .string(serverName),
                "version": .string(GhostHands.version),
            ]),
        ])
    }

    /// Route ONE already-decoded JSON-RPC message. Pure. The executable calls
    /// this; on `.dispatchTool` it runs the verb and writes
    /// `MCPMapping.*` results, on `.respond` it writes the response verbatim,
    /// on `.ignore` it writes nothing.
    public static func route(_ value: JSONValue) -> Decision {
        switch JSONRPCRequest.parse(value) {
        case let .failure(err):
            // No reliable id on a malformed object → reply with null id.
            let code = (err == .notAnObject)
                ? JSONRPCError.invalidRequest : JSONRPCError.invalidRequest
            return .respond(JSONRPCResponse.error(
                id: .null, code: code, message: "invalid request"))
        case let .success(req):
            return route(req)
        }
    }

    /// Route a validated request.
    public static func route(_ req: JSONRPCRequest) -> Decision {
        switch req.method {
        case "initialize":
            return .respond(JSONRPCResponse.success(
                id: req.id, result: initializeResult()))

        case "notifications/initialized":
            return .ignore   // a notification: accept silently

        case "tools/list":
            return .respond(JSONRPCResponse.success(
                id: req.id, result: MCPTools.listResult()))

        case "tools/call":
            return routeToolsCall(req)

        case "ping":
            // Optional MCP keepalive: empty result.
            return .respond(JSONRPCResponse.success(id: req.id, result: .object([:])))

        default:
            // A notification we don't recognise: ignore. A request: method-not-found.
            if req.isNotification { return .ignore }
            return .respond(JSONRPCResponse.error(
                id: req.id, code: JSONRPCError.methodNotFound,
                message: "method not found: \(req.method)"))
        }
    }

    /// Validate a `tools/call`: extract `name` + `arguments`, check the tool
    /// exists and all required args are present non-empty strings. On any
    /// failure return an isError:true tool result (so the model recovers) wrapped
    /// in a success envelope — NOT a protocol error.
    static func routeToolsCall(_ req: JSONRPCRequest) -> Decision {
        guard let params = req.params, case let .object(p) = params else {
            return .respond(JSONRPCResponse.success(
                id: req.id, result: MCPMapping.usageError("missing params for tools/call")))
        }
        guard let name = p["name"]?.stringValue else {
            return .respond(JSONRPCResponse.success(
                id: req.id, result: MCPMapping.usageError("tools/call: missing tool name")))
        }
        guard let tool = MCPTools.tool(named: name) else {
            return .respond(JSONRPCResponse.success(
                id: req.id, result: MCPMapping.usageError("unknown tool: \(name)")))
        }
        let arguments = p["arguments"] ?? .object([:])
        // Validate required args are present as non-empty strings.
        if let missing = firstMissingRequired(tool: tool, arguments: arguments) {
            return .respond(JSONRPCResponse.success(
                id: req.id,
                result: MCPMapping.usageError(
                    "tool \(name): missing required argument \(missing.debugDescription)")))
        }
        return .dispatchTool(id: req.id, name: name, arguments: arguments)
    }

    /// The first required property that is absent or not a non-empty string, or
    /// nil when all are present. Pure — lets a test pin the missing-arg path.
    public static func firstMissingRequired(tool: MCPTools.Tool,
                                            arguments: JSONValue) -> String? {
        let args = arguments.objectValue ?? [:]
        for key in tool.required {
            guard let v = args[key]?.stringValue, !v.isEmpty else { return key }
        }
        return nil
    }

    /// Read an optional string argument (nil if absent / not a string).
    public static func string(_ key: String, from arguments: JSONValue) -> String? {
        arguments.objectValue?[key]?.stringValue
    }
}
