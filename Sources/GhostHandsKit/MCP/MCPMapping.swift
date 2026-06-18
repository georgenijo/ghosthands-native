import Foundation

/// The PURE honesty boundary: GhostHands Outcomes → MCP `tools/call` results.
///
/// THE ONE RULE this file enforces, encoded so a test can pin it: three distinct
/// outputs, never collapsed —
///   (a) `verified == true`  → normal result (isError:false), text says "verified: <evidence>"
///   (b) `verified == false` → normal result (isError:false), text CONTAINS "unverified"
///   (c) thrown GhostHandsError → result with isError:true carrying `error.description`
/// A bare success string is NEVER produced for a dispatched-unverified outcome.
///
/// All functions here take fabricated Outcome / error values and return a
/// `JSONValue` — no AX, no stdio — so the mapping is hermetically unit-testable.
public enum MCPMapping {
    /// An MCP tool result: a content-block array plus the isError flag. Built as
    /// a `JSONValue` so the server can embed it directly under `result`.
    public static func result(text: String, isError: Bool,
                              structured: JSONValue? = nil) -> JSONValue {
        var obj: [String: JSONValue] = [
            "content": .array([
                .object(["type": .string("text"), "text": .string(text)]),
            ]),
            "isError": .bool(isError),
        ]
        if let structured {
            obj["structuredContent"] = structured
        }
        return .object(obj)
    }

    /// A REFUSE: a thrown `GhostHandsError` becomes a tool result with
    /// isError:true carrying the honest one-liner. NOT a protocol error.
    public static func refuse(_ error: GhostHandsError) -> JSONValue {
        result(text: error.description, isError: true)
    }

    /// A tool-call error that is NOT a GhostHands REFUSE — e.g. a missing
    /// required argument. Still surfaced as an isError:true tool result (so the
    /// model can recover) rather than a JSON-RPC protocol error.
    public static func usageError(_ message: String) -> JSONValue {
        result(text: message, isError: true)
    }

    // MARK: - Per-outcome mappings (mirror CLI.swift report*/reportValue/reportAct)

    /// click → ClickOutcome.
    public static func map(_ o: ClickOutcome) -> JSONValue {
        let where_ = "(role=\(o.role)) in \(o.app)"
        let text: String
        if o.verified {
            text = "clicked \(o.name.debugDescription) \(where_) — verified: "
                + "\(o.evidence ?? "changed")"
        } else {
            text = "pressed \(o.name.debugDescription) \(where_) — AXPress accepted; "
                + "no observable change (effect unverified)"
        }
        return result(text: text, isError: false, structured: structured(
            verb: "click", app: o.app, name: o.name, role: o.role, action: "AXPress",
            axAccepted: o.axAccepted, verified: o.verified, evidence: o.evidence))
    }

    /// type / set-value → ValueOutcome.
    public static func map(_ o: ValueOutcome) -> JSONValue {
        let where_ = "(role=\(o.role)) in \(o.app)"
        let text: String
        if o.verified {
            let how = o.exact ? "verified" : "verified (changed)"
            text = "\(o.verb) \(o.intended.debugDescription) into \(o.name.debugDescription) "
                + "\(where_) — \(how): \(o.evidence ?? "changed")"
        } else {
            let was = o.valueAfter.map { $0.debugDescription } ?? "empty"
            text = "set \(o.name.debugDescription) \(where_) via AXValue — AX accepted; "
                + "field value unchanged (\(was)) (effect unverified)"
        }
        return result(text: text, isError: false, structured: structured(
            verb: o.verb, app: o.app, name: o.name, role: o.role, action: "AXValue",
            axAccepted: o.axAccepted, verified: o.verified, evidence: o.evidence))
    }

    /// doubleclick / act → ActOutcome.
    public static func map(_ o: ActOutcome) -> JSONValue {
        let where_ = "(role=\(o.role)) in \(o.app)"
        let text: String
        if o.verified {
            text = "\(o.verbLabel) \(o.name.debugDescription) \(where_) — verified: "
                + "\(o.evidence ?? "changed")"
        } else {
            text = "\(o.verbLabel) \(o.name.debugDescription) \(where_) — "
                + "\(o.action) accepted; no observable change (effect unverified)"
        }
        return result(text: text, isError: false, structured: structured(
            verb: o.verbLabel, app: o.app, name: o.name, role: o.role, action: o.action,
            axAccepted: o.axAccepted, verified: o.verified, evidence: o.evidence))
    }

    /// find → FindOutcome (read tier; no verified/dispatch axis). Not-found is a
    /// clean result (isError:false) — it is a successful probe, not a refuse.
    public static func map(_ o: GhostHands.FindOutcome) -> JSONValue {
        if o.found, let line = FindResult.report(o.hits) {
            return result(text: "found in \(o.app): \(line)", isError: false)
        }
        return result(text: "not found: \(o.query.debugDescription) in \(o.app)",
                      isError: false)
    }

    /// snapshot → SnapshotResult, rendered as text or JSON per `asJSON`.
    public static func map(_ o: GhostHands.SnapshotResult, asJSON: Bool) -> JSONValue {
        let body: String
        if asJSON {
            body = SnapshotRender.json(o.forest)
        } else {
            let tree = SnapshotRender.ax(o.forest)
            body = tree.isEmpty ? "(empty tree)" : tree
        }
        let text = "\(o.count) elements in \(o.app)\n\(body)"
        return result(text: text, isError: false)
    }

    /// shot → ShotOutcome. A returned outcome means real pixels on disk.
    public static func map(_ o: GhostHands.ShotOutcome) -> JSONValue {
        result(text: "wrote \(o.path) (\(o.width)×\(o.height)) for \(o.app)",
               isError: false)
    }

    // MARK: - structured side-channel (so a programmatic brain reads verified directly)

    static func structured(verb: String, app: String, name: String, role: String,
                           action: String, axAccepted: Bool, verified: Bool,
                           evidence: String?) -> JSONValue {
        var obj: [String: JSONValue] = [
            "verb": .string(verb),
            "app": .string(app),
            "name": .string(name),
            "role": .string(role),
            // The RAW AX action actually dispatched (e.g. "AXPress", "AXShowMenu",
            // "AXValue") — so a brain reading ONLY structuredContent can audit
            // which action ran, matching what the human-readable text states.
            "action": .string(action),
            "axAccepted": .bool(axAccepted),
            "verified": .bool(verified),
        ]
        if let evidence { obj["evidence"] = .string(evidence) }
        return .object(obj)
    }
}
