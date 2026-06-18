import Foundation

/// The PURE MCP tool registry: the eight GhostHands verbs, each described as an
/// MCP tool with a JSON Schema for its arguments. No AX, no stdio — just the
/// static surface, so `tools/list` can be built and asserted hermetically.
///
/// MCP tool names must match `^[a-zA-Z0-9_-]+$`. We use `set_value` (underscore)
/// where the CLI verb is `set-value`.
public enum MCPTools {
    /// One advertised tool: its name, human description, and the property/required
    /// shape of its `inputSchema`.
    public struct Tool: Sendable, Equatable {
        public let name: String
        public let description: String
        /// (propertyName, jsonType, description) in declaration order.
        public let properties: [Property]
        public let required: [String]

        public init(name: String, description: String,
                    properties: [Property], required: [String]) {
            self.name = name
            self.description = description
            self.properties = properties
            self.required = required
        }
    }

    public struct Property: Sendable, Equatable {
        public let name: String
        public let type: String       // "string"
        public let description: String
        /// When non-empty, an enum constraint (e.g. snapshot format, act action).
        public let enumValues: [String]

        public init(name: String, type: String, description: String,
                    enumValues: [String] = []) {
            self.name = name
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }
    }

    /// The canonical app-target property, shared by every verb.
    static let appProp = Property(
        name: "app", type: "string",
        description: "target app: bundle id, pid, or (partial) app name")

    /// The full registry, in advertise order.
    public static let all: [Tool] = [
        Tool(name: "click",
             description: "Press a named control via the Accessibility tree (cursor-less, "
                 + "background-safe). Verified only by an observed change.",
             properties: [
                 Property(name: "name", type: "string",
                          description: "the control's on-screen name"),
                 appProp,
             ],
             required: ["name", "app"]),

        Tool(name: "type",
             description: "Set a TEXT-ENTRY field's value via AX, then read it back to "
                 + "verify. Refuses on a secure (password) field.",
             properties: [
                 Property(name: "text", type: "string",
                          description: "the text to enter"),
                 Property(name: "field", type: "string",
                          description: "the text field's name"),
                 appProp,
             ],
             required: ["text", "field", "app"]),

        Tool(name: "set_value",
             description: "Set a non-text control (checkbox/slider/popup) via AX, then "
                 + "read it back to verify. Type-coerces (on/off→1/0, numeric).",
             properties: [
                 Property(name: "value", type: "string",
                          description: "the value to set"),
                 Property(name: "control", type: "string",
                          description: "the control's name"),
                 appProp,
             ],
             required: ["value", "control", "app"]),

        Tool(name: "doubleclick",
             description: "Double-activate a row/item/file (prefers AXOpen, falls back to "
                 + "AXPress). Verified by observed effect where in-AX observable.",
             properties: [
                 Property(name: "name", type: "string",
                          description: "the item's name"),
                 appProp,
             ],
             required: ["name", "app"]),

        Tool(name: "act",
             description: "Invoke a named AX action on a control. Verified by read-back "
                 + "where observable.",
             properties: [
                 Property(name: "action", type: "string",
                          description: "the action to invoke",
                          enumValues: ["open", "confirm", "pick", "show-menu",
                                       "cancel", "raise", "increment", "decrement"]),
                 Property(name: "name", type: "string",
                          description: "the control's name"),
                 appProp,
             ],
             required: ["action", "name", "app"]),

        Tool(name: "snapshot",
             description: "Dump the app's AX tree (pure read). `format` selects the "
                 + "indented text tree (ax) or a JSON array (json).",
             properties: [
                 appProp,
                 Property(name: "format", type: "string",
                          description: "output format (default ax)",
                          enumValues: ["ax", "json"]),
             ],
             required: ["app"]),

        Tool(name: "find",
             description: "Existence probe: does a named element (incl. static text / "
                 + "disabled controls) exist on screen? Pure read.",
             properties: [
                 Property(name: "query", type: "string",
                          description: "the element name to probe for"),
                 appProp,
             ],
             required: ["query", "app"]),

        Tool(name: "shot",
             description: "Honest screenshot of the app's frontmost window to a PNG path. "
                 + "Refuses (no file) without Screen Recording — never a black PNG.",
             properties: [
                 appProp,
                 Property(name: "out_path", type: "string",
                          description: "absolute path to write the PNG"),
             ],
             required: ["app", "out_path"]),
    ]

    public static func tool(named name: String) -> Tool? {
        all.first { $0.name == name }
    }

    // MARK: - JSON rendering (pure)

    /// One tool → its `tools/list` JSON entry (name + description + inputSchema).
    public static func json(for tool: Tool) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for p in tool.properties {
            var schema: [String: JSONValue] = [
                "type": .string(p.type),
                "description": .string(p.description),
            ]
            if !p.enumValues.isEmpty {
                schema["enum"] = .array(p.enumValues.map { .string($0) })
            }
            props[p.name] = .object(schema)
        }
        let inputSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(tool.required.map { .string($0) }),
        ])
        return .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": inputSchema,
        ])
    }

    /// The full `tools/list` result object: `{"tools":[ ... ]}`.
    public static func listResult() -> JSONValue {
        .object(["tools": .array(all.map { json(for: $0) })])
    }
}
