import Foundation

/// A minimal, PURE JSON-RPC 2.0 layer for the MCP-over-stdio server.
///
/// Everything in this file is free of AX, stdio, and process state so it can be
/// driven on fabricated request strings and fabricated Outcome values in
/// hermetic tests. The server loop (`Sources/ghosthands-mcp/main.swift`) does
/// the I/O; this is just bytes → values → bytes.
///
/// FRAMING (documented, chosen): newline-delimited JSON. Each JSON-RPC message
/// is ONE compact JSON object on a single line, terminated by `\n`. This is the
/// current MCP stdio transport: embedded newlines are forbidden inside a
/// message, and `JSONSerialization`/`Codable` never emit a literal newline in a
/// compact object, so "one object = one line" holds with no escaping work. (The
/// `Content-Length` header framing is the LSP convention / an older alternate
/// transport; we deliberately do not use it.)
public enum MCP {}

// MARK: - JSON value (a tiny dynamic JSON model)

/// A minimal dynamic JSON value, so the pure layer can parse/inspect/build
/// arbitrary JSON-RPC payloads without bespoke Codable structs per method.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // Convenience accessors used by the request router.
    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }

    public subscript(_ key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }
}

extension JSONValue {
    /// Build from the output of `JSONSerialization.jsonObject`.
    public init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // Distinguish a real Bool (CFBoolean) from a numeric NSNumber.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]:
            self = .object(o.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    /// Lower back to a Foundation object for `JSONSerialization`.
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(n):
            // Render integral doubles as integers so ids round-trip cleanly.
            if n == n.rounded(), abs(n) < 1e15 { return Int(n) }
            return n
        case let .string(s): return s
        case let .array(a): return a.map { $0.foundationObject }
        case let .object(o): return o.mapValues { $0.foundationObject }
        }
    }
}

// MARK: - Framing (pure, no stdio)

public enum JSONRPCFraming {
    /// Parse one newline-delimited line into a `JSONValue`. Returns nil for blank
    /// lines (tolerated) and throws-as-nil for malformed JSON — the caller maps a
    /// malformed line to a `-32700` parse error.
    public static func decodeLine(_ line: String) -> JSONValue? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSONValue(any: obj)
    }

    /// Encode a `JSONValue` as one compact line WITHOUT the trailing newline. The
    /// server adds the single `\n` when it writes. Sorted keys keep output stable
    /// for tests.
    public static func encodeLine(_ value: JSONValue) -> String {
        let obj = value.foundationObject
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                  withJSONObject: obj, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Parsed request

/// A parsed JSON-RPC message. `id` is preserved as a `JSONValue` so a string,
/// number, or null id all round-trip unchanged. A notification (no `id`) has
/// `id == nil` and MUST NOT be answered.
public struct JSONRPCRequest: Sendable, Equatable {
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?

    public init(id: JSONValue?, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// True when the message carries no id → a notification, send no response.
    public var isNotification: Bool { id == nil }
}

public enum JSONRPCParseError: Error, Equatable {
    case notAnObject       // -32600 invalid request
    case missingMethod     // -32600 invalid request
}

extension JSONRPCRequest {
    /// Validate a decoded `JSONValue` into a request. The absence of `id` is a
    /// notification (legal), the absence of `method` is invalid.
    public static func parse(_ value: JSONValue) -> Result<JSONRPCRequest, JSONRPCParseError> {
        guard case let .object(obj) = value else { return .failure(.notAnObject) }
        guard let method = obj["method"]?.stringValue else { return .failure(.missingMethod) }
        // `id` present (any non-null JSON value, even explicit null) ⇒ request.
        // Per JSON-RPC, a missing `id` key is a notification.
        let id = obj["id"]
        return .success(JSONRPCRequest(id: id, method: method, params: obj["params"]))
    }
}

// MARK: - Response building (pure)

public enum JSONRPCError {
    public static let parse = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}

public enum JSONRPCResponse {
    /// A success response: `{"jsonrpc":"2.0","id":<id>,"result":<result>}`.
    public static func success(id: JSONValue?, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "result": result,
        ])
    }

    /// A protocol-level error: `{"jsonrpc":"2.0","id":<id>,"error":{...}}`.
    /// Reserved for transport/method faults — NEVER a GhostHands REFUSE (those
    /// are `isError:true` tool results, see `MCPMapping`).
    public static func error(id: JSONValue?, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
    }
}
