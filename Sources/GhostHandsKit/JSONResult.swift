import Foundation

/// The ONE machine-readable envelope every verb emits under `--json`.
///
/// HONESTY IS THE CONTRACT: a JSONResult is built from the SAME outcome/verdict
/// the human one-liner is built from, so its `status` can NEVER claim more than
/// the human line. A `dispatched` (acted, no proof) stays `dispatched`; a
/// `verified` (observed change) stays `verified`. The envelope is a pure
/// re-SHAPING of an already-decided verdict, never a re-decision — there is no
/// path here that can upgrade an unproven action to a proven one.
///
/// The schema (stable, documented once, here):
/// ```
/// { "verb":   <string>,                     // the verb that ran
///   "status": "verified" | "dispatched"     // acted + observed proof | acted, no proof
///           | "refused"                       // a thrown GhostHandsError (nonzero exit)
///           | "pass" | "fail"                 // an assert verdict
///           | "ok",                           // a pure read that succeeded
///   "app":    <string?>,                    // the resolved app, when known
///   "target": <string?>,                    // the element/selector/url acted on
///   "evidence": <string?>,                  // the OBSERVED proof — present iff verified/pass-ish
///   "value":  <string?>,                    // a read-back value, when relevant
///   "fields": { ... },                      // verb-specific extras (selector, port, frame, …)
///   "error":  <string?> }                   // present iff status == "refused"
/// ```
///
/// `fields` carries the verb-specific evidence the human line embeds (before →
/// after frames, poll counts, hit lists, …). The encoder emits keys in a STABLE
/// order so the bytes are deterministic and hermetically testable; `nil`
/// optionals are OMITTED entirely (never `"key": null`) so an absent field reads
/// as absent, never as a fabricated empty.
public struct JSONResult: Sendable, Equatable {
    /// The honest status — mirrors the human verdict EXACTLY.
    public enum Status: String, Sendable, Equatable {
        /// Acted AND observed a world change (the human "verified:" line).
        case verified
        /// Acted; the AX/event was accepted but NO change was observed (the human
        /// "…unverified" line). NEVER promoted to `verified`.
        case dispatched
        /// A thrown `GhostHandsError` — the same refuse that exits nonzero in the
        /// human path. Carries `error`.
        case refused
        /// An `assert` that was CHECKED and held (exit 0).
        case pass
        /// An `assert` that was CHECKED and did not hold (exit 1).
        case fail
        /// A pure READ that succeeded (snapshot / find / web read / extract / …) —
        /// the data lives in `fields`.
        case ok
    }

    public var verb: String
    public var status: Status
    public var app: String?
    public var target: String?
    public var evidence: String?
    public var value: String?
    /// Verb-specific extras, in the order inserted (the encoder preserves it).
    public var fields: [(key: String, value: GHJSONValue)]
    public var error: String?

    public init(verb: String, status: Status, app: String? = nil, target: String? = nil,
                evidence: String? = nil, value: String? = nil,
                fields: [(key: String, value: GHJSONValue)] = [], error: String? = nil) {
        self.verb = verb
        self.status = status
        self.app = app
        self.target = target
        self.evidence = evidence
        self.value = value
        self.fields = fields
        self.error = error
    }

    public static func == (lhs: JSONResult, rhs: JSONResult) -> Bool {
        lhs.verb == rhs.verb && lhs.status == rhs.status && lhs.app == rhs.app
            && lhs.target == rhs.target && lhs.evidence == rhs.evidence
            && lhs.value == rhs.value && lhs.error == rhs.error
            && lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    // MARK: - encoding

    /// Encode the envelope to a single-line JSON object with a STABLE key order:
    /// verb, status, app, target, evidence, value, fields, error. A nil top-level
    /// optional is OMITTED (never serialized as null). `fields` is always present
    /// (an empty object `{}` when there are none) so a consumer can rely on the
    /// key existing.
    public func encoded() -> String {
        var parts: [String] = []
        parts.append("\"verb\":\(GHJSONValue.encodeString(verb))")
        parts.append("\"status\":\(GHJSONValue.encodeString(status.rawValue))")
        if let app { parts.append("\"app\":\(GHJSONValue.encodeString(app))") }
        if let target { parts.append("\"target\":\(GHJSONValue.encodeString(target))") }
        if let evidence { parts.append("\"evidence\":\(GHJSONValue.encodeString(evidence))") }
        if let value { parts.append("\"value\":\(GHJSONValue.encodeString(value))") }
        parts.append("\"fields\":\(GHJSONValue.object(fields).encoded())")
        if let error { parts.append("\"error\":\(GHJSONValue.encodeString(error))") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Emit the envelope to stdout as one line. The SOLE side-effecting hook the
    /// CLI calls — kept here so the format lives in one place. (The CLI owns the
    /// exit code; this only prints.)
    public func emit() {
        FileHandle.standardOutput.write(Data((encoded() + "\n").utf8))
    }
}

/// A minimal, dependency-free JSON value just rich enough to shape `fields`. We
/// hand-roll the encoder (no new SwiftPM dep, and a deterministic key order so
/// the output is byte-stable for hermetic tests) rather than reach for a Codable
/// graph over the many heterogeneous outcome structs.
public enum GHJSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    /// An ORDERED object — insertion order is preserved on encode (a plain
    /// dictionary would scramble the keys, breaking byte-stability).
    case object([(key: String, value: GHJSONValue)])
    case array([GHJSONValue])

    public static func == (lhs: GHJSONValue, rhs: GHJSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        case let (.object(a), .object(b)):
            return a.count == b.count
                && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(a), .array(b)): return a == b
        default: return false
        }
    }

    public func encoded() -> String {
        switch self {
        case let .string(s): return GHJSONValue.encodeString(s)
        case let .int(n): return String(n)
        case let .double(d):
            // Finite → the plain literal; non-finite has no JSON form → null
            // (honest absence, never a crash or a fabricated 0).
            return d.isFinite ? trimDouble(d) : "null"
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        case let .object(pairs):
            let body = pairs.map { "\(GHJSONValue.encodeString($0.key)):\($0.value.encoded())" }
                .joined(separator: ",")
            return "{" + body + "}"
        case let .array(items):
            return "[" + items.map { $0.encoded() }.joined(separator: ",") + "]"
        }
    }

    /// Render a Double without a trailing ".0" for integers, but otherwise its
    /// shortest round-tripping form — so `0.0` → "0", `0.5` → "0.5".
    private func trimDouble(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int(d))
        }
        return String(d)
    }

    /// RFC 8259 string escaping — the ONLY place a string is quoted, so every
    /// field (verb, evidence, a nested hit label, …) is escaped the same way.
    /// Escapes the mandatory set (`"` `\` and the C0 controls) so a label with a
    /// newline, a quote, or a tab never breaks the line or injects structure.
    public static func encodeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - convenience field builders

extension GHJSONValue {
    /// A string field that omits itself when nil — built as a pair list helper so
    /// callers can `+= GHJSONValue.opt("frame", value)` without a null leaking in.
    public static func optString(_ key: String, _ value: String?)
        -> [(key: String, value: GHJSONValue)] {
        value.map { [(key, GHJSONValue.string($0))] } ?? []
    }

    public static func optInt(_ key: String, _ value: Int?)
        -> [(key: String, value: GHJSONValue)] {
        value.map { [(key, GHJSONValue.int($0))] } ?? []
    }

    public static func optBool(_ key: String, _ value: Bool?)
        -> [(key: String, value: GHJSONValue)] {
        value.map { [(key, GHJSONValue.bool($0))] } ?? []
    }

    public static func optDouble(_ key: String, _ value: Double?)
        -> [(key: String, value: GHJSONValue)] {
        value.map { [(key, GHJSONValue.double($0))] } ?? []
    }
}
