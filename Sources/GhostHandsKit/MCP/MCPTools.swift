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
        public let type: String       // "string" | "number" | "integer" | "boolean"
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

    /// The `browser` target shared by the web/navigate verbs — same shape as
    /// `app`, but the optionality differs (navigate may auto-pick), so it is a
    /// distinct prop with its own description.
    static let browserProp = Property(
        name: "browser", type: "string",
        description: "target browser app: bundle id, pid, or (partial) app name")

    // MARK: opt-in flags shared across web / pixel / window verbs

    /// `--visible` opt-in: the verb defaults to INVISIBLE (cursor-less,
    /// background-safe). Set true ONLY to fall to the visible HID route (moves
    /// the real cursor, may steal focus). Default false — same as the CLI.
    static let visibleProp = Property(
        name: "visible", type: "boolean",
        description: "use the visible HID route (moves the cursor, may steal "
            + "focus); default false (invisible, background-safe)")

    /// The web-lens trio: `--cdp`/`--ax`/`--debug-port`/`--relaunch`. Default is
    /// the `auto` lens (CDP-when-reachable, else AX) on port 9222, relaunch OFF —
    /// identical to the CLI.
    static let cdpProp = Property(
        name: "cdp", type: "boolean",
        description: "force the CDP lens (DevTools); default auto (CDP when "
            + "reachable, else the AX tree)")
    static let axLensProp = Property(
        name: "ax", type: "boolean",
        description: "force the AX lens (never CDP); default auto")
    static let debugPortProp = Property(
        name: "debugPort", type: "integer",
        description: "the DevTools debug port for the CDP lens (default 9222)")
    static let relaunchProp = Property(
        name: "relaunch", type: "boolean",
        description: "CONSENT GATE: when the debug port is closed, launch a NEW "
            + "isolated throwaway browser for automation (never your real "
            + "profile); default false")

    /// The shared locator disambiguators (`--role`/`--text`/`--nth`) for the
    /// named-control verbs. All optional; absent ⇒ refuse-on-ambiguous intact.
    static let roleProp = Property(
        name: "role", type: "string",
        description: "restrict candidates to this AX role (e.g. AXButton)")
    static let textProp = Property(
        name: "text", type: "string",
        description: "restrict candidates whose label/value contains this substring")
    static let nthProp = Property(
        name: "nth", type: "integer",
        description: "pick the i-th match (0-based); out of range REFUSES")

    /// The shared `--window <id|title>` selector for the window-mutate verbs.
    static let windowProp = Property(
        name: "window", type: "string",
        description: "pick a window by id (all-digits) or title; required when "
            + "the app has more than one window")

    /// The advertised registry, in advertise order — every interactive-actuation
    /// and observation verb a remote brain drives a live UI with. The CLI's
    /// `click-at` (raw-pixel click), `replay`, and `record` (trajectory file
    /// capture/playback) are deliberately NOT advertised: MCP exposes only the
    /// named-control act tier, and record/replay are a local-runner concern, not a
    /// remote per-call verb.
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

        Tool(name: "menu",
             description: "Drive an app's menu bar by a ' > '-separated path "
                 + "(e.g. \"File > Open Recent > ~/proj\"). AXPress through each "
                 + "level, no cursor/focus steal. Always dispatched-unverified (a menu "
                 + "action has no in-AX observable); refuses on an unmatched/ambiguous "
                 + "segment or a path past a leaf.",
             properties: [
                 Property(name: "path", type: "string",
                          description: "menu path, ' > '-separated (File > New File)"),
                 appProp,
             ],
             required: ["path", "app"]),

        Tool(name: "ocr",
             description: "Vision OCR a window: recognize on-screen text + where each line "
                 + "sits (screen rect), for surfaces with no AX and no DOM (canvas, games, "
                 + "remote screens). Pure read; needs Screen Recording. The universal "
                 + "fallback eye.",
             properties: [appProp],
             required: ["app"]),

        Tool(name: "apps",
             description: "List running GUI apps (name, bundle id, pid, frontmost) — "
                 + "the app-level eye for 'what's open?'. Pure read; faceless daemons "
                 + "excluded. Pair with click \"<App>\" Dock to open one.",
             properties: [],
             required: []),

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

        // MARK: - focus / right-click / scroll / drag (named-control act tier)

        Tool(name: "focus",
             description: "Move keyboard focus to a named control via AXFocused, then read "
                 + "it back. Verified only when AXFocused reads back true.",
             properties: [
                 Property(name: "name", type: "string",
                          description: "the control's name"),
                 appProp, roleProp, textProp, nthProp,
             ],
             required: ["name", "app"]),

        Tool(name: "right_click",
             description: "Open a control's context menu via AXShowMenu (invisible), falling "
                 + "back to a pixel right-click. Verified only when a context menu appears.",
             properties: [
                 Property(name: "name", type: "string",
                          description: "the control's name"),
                 appProp, visibleProp, roleProp, textProp, nthProp,
             ],
             required: ["name", "app"]),

        Tool(name: "scroll",
             description: "Scroll a container via the AX scroll bar / wheel. Verified only by "
                 + "an observed scroll-bar position change (else dispatched-unverified).",
             properties: [
                 appProp,
                 Property(name: "direction", type: "string",
                          description: "scroll direction",
                          enumValues: ["up", "down", "left", "right"]),
                 Property(name: "amount", type: "number",
                          description: "number of pages to scroll (default 1)"),
                 Property(name: "container", type: "string",
                          description: "the scroll area's name (default: frontmost window's)"),
                 visibleProp,
             ],
             required: ["app", "direction"]),

        Tool(name: "drag",
             description: "Drag one named element onto another (element-to-element). Resolves "
                 + "both, aims at their centers, witnesses the from-element's move. Verified "
                 + "only by an observed move/vanish.",
             properties: [
                 Property(name: "from", type: "string",
                          description: "the source element's name"),
                 Property(name: "to", type: "string",
                          description: "the destination element's name"),
                 appProp, visibleProp,
             ],
             required: ["from", "to", "app"]),

        // MARK: - extract / dialog / wait / assert (read + checked tiers)

        Tool(name: "extract",
             description: "Read a table/outline/list into rows (pure read). Refuses on no "
                 + "tabular container (distinct from a present-but-empty table).",
             properties: [
                 appProp,
                 Property(name: "container", type: "string",
                          description: "the table/outline/list name (default: frontmost window's)"),
             ],
             required: ["app"]),

        Tool(name: "dialog",
             description: "Detect a modal sheet/alert (its title, message, buttons) — or, with "
                 + "`button`, press a button and verify the dialog dismissed.",
             properties: [
                 appProp,
                 Property(name: "button", type: "string",
                          description: "OPTIONAL: a button to press (omit to just detect)"),
             ],
             required: ["app"]),

        Tool(name: "wait",
             description: "Poll until a named element appears (or, with `gone`, disappears) up "
                 + "to a timeout. A timeout is a REFUSE (isError), never a faked success.",
             properties: [
                 Property(name: "name", type: "string",
                          description: "the element to wait for"),
                 appProp,
                 Property(name: "gone", type: "boolean",
                          description: "wait for the element to DISAPPEAR (default: appear)"),
                 Property(name: "timeout", type: "number",
                          description: "deadline in seconds (default 5)"),
                 Property(name: "interval", type: "number",
                          description: "poll cadence in milliseconds (default 150)"),
             ],
             required: ["name", "app"]),

        Tool(name: "assert",
             description: "Machine-checkable assertion: exists | absent | value | count. PASS or "
                 + "FAIL is a checked verdict; a refuse (cannot check) is an isError.",
             properties: [
                 Property(name: "kind", type: "string",
                          description: "the assertion kind",
                          enumValues: ["exists", "absent", "value", "count"]),
                 Property(name: "name", type: "string",
                          description: "the control's name"),
                 appProp,
                 Property(name: "expected", type: "string",
                          description: "the expected value (kind=value) or count (kind=count)"),
             ],
             required: ["kind", "name", "app"]),

        // MARK: - clipboard / navigate / key / install (system tier)

        Tool(name: "clipboard_read",
             description: "Read the live pasteboard string (pure read). A blank clipboard is a "
                 + "real, honest empty state — never fabricated text.",
             properties: [],
             required: []),

        Tool(name: "clipboard_write",
             description: "Set the pasteboard, then read it back. Verified only when the "
                 + "read-back matches (else dispatched-unverified).",
             properties: [
                 Property(name: "text", type: "string",
                          description: "the text to write to the clipboard"),
             ],
             required: ["text"]),

        Tool(name: "navigate",
             description: "Open a URL in a Chromium browser and witness the landed page. "
                 + "Verified only when the landed URL/title is confirmed; refuses on a "
                 + "malformed URL.",
             properties: [
                 Property(name: "url", type: "string",
                          description: "the URL to navigate to"),
                 Property(name: "browser", type: "string",
                          description: "OPTIONAL: the browser (omit to auto-pick a running one)"),
             ],
             required: ["url"]),

        Tool(name: "key",
             description: "Post a key / chord (e.g. cmd+shift+t) to an app (or the focused app "
                 + "if omitted). ALWAYS dispatched-unverified — a key has no observable.",
             properties: [
                 Property(name: "spec", type: "string",
                          description: "the key spec: <key> or <mod>+<key> (mods: cmd|shift|alt|ctrl)"),
                 Property(name: "app", type: "string",
                          description: "OPTIONAL: target app (omit to post to the focused app)"),
                 visibleProp,
             ],
             required: ["spec"]),

        Tool(name: "install",
             description: "Install a .app from a DMG and verify by reading its "
                 + "CFBundleIdentifier. Refuses to overwrite without `force`; verified only "
                 + "when the installed bundle is confirmed.",
             properties: [
                 Property(name: "dmg", type: "string",
                          description: "absolute path to the .dmg"),
                 Property(name: "dest", type: "string",
                          description: "OPTIONAL: destination dir (default /Applications)"),
                 Property(name: "force", type: "boolean",
                          description: "overwrite an existing install (default false: refuse)"),
             ],
             required: ["dmg"]),

        // MARK: - windows (read) + window move/resize/raise (mutate)

        Tool(name: "windows",
             description: "List an app's on-screen windows: id, title, frame, display, and AX "
                 + "flags (main/focused/minimized). Pure read.",
             properties: [appProp],
             required: ["app"]),

        Tool(name: "window_move",
             description: "Move a window's top-left to (x,y) via AX, then read back. CLAMPED "
                 + "(OS-constrained) is honest-dispatched; verified only on an exact landing.",
             properties: [
                 Property(name: "x", type: "number", description: "target top-left x"),
                 Property(name: "y", type: "number", description: "target top-left y"),
                 appProp, windowProp,
             ],
             required: ["x", "y", "app"]),

        Tool(name: "window_resize",
             description: "Resize a window to w×h via AX, then read back. CLAMPED "
                 + "(OS-constrained) is honest-dispatched; verified only on an exact landing.",
             properties: [
                 Property(name: "w", type: "number", description: "target width"),
                 Property(name: "h", type: "number", description: "target height"),
                 appProp, windowProp,
             ],
             required: ["w", "h", "app"]),

        Tool(name: "window_raise",
             description: "Raise a window via AXRaise. ALWAYS dispatched-unverified — z-order "
                 + "has no AX read-back; never claims app activation.",
             properties: [appProp, windowProp],
             required: ["app"]),

        // MARK: - web read / tabs / click / fill / html / eval

        Tool(name: "web_read",
             description: "Read the page's meaningful controls/text via the CDP or AX lens "
                 + "(pure read). Names the served lens honestly.",
             properties: [
                 browserProp, cdpProp, axLensProp, debugPortProp, relaunchProp,
             ],
             required: ["browser"]),

        Tool(name: "web_tabs",
             description: "List the browser's tabs (title + selected) via the CDP or AX lens "
                 + "(pure read). Refuses when no tab strip is exposed.",
             properties: [
                 browserProp, cdpProp, axLensProp, debugPortProp, relaunchProp,
             ],
             required: ["browser"]),

        Tool(name: "web_click",
             description: "Click a CSS-selected DOM element (CDP only). Verified only by an "
                 + "observed navigation; refuses on a missing/occluded selector.",
             properties: [
                 Property(name: "selector", type: "string",
                          description: "a CSS selector for the target element"),
                 browserProp, debugPortProp, relaunchProp,
             ],
             required: ["selector", "browser"]),

        Tool(name: "web_fill",
             description: "Fill a CSS-selected input (CDP only), then read it back. Verified "
                 + "only when the value read-back matches.",
             properties: [
                 Property(name: "selector", type: "string",
                          description: "a CSS selector for the input"),
                 Property(name: "text", type: "string", description: "the text to fill"),
                 browserProp, debugPortProp, relaunchProp,
             ],
             required: ["selector", "text", "browser"]),

        Tool(name: "web_type",
             description: "Type into a web/Electron element via CDP Input.insertText (CDP "
                 + "only) — drives plain inputs AND contenteditable/custom editors (Cursor's "
                 + "agent box, Lexical/ProseMirror, Monaco) where a value-set is a no-op. "
                 + "Verified by text read-back; submit=true then presses Enter (send reported "
                 + "dispatched). Accepts an @eN ref or CSS selector.",
             properties: [
                 Property(name: "selector", type: "string",
                          description: "an @eN ref or CSS selector for the input/editor"),
                 Property(name: "text", type: "string", description: "the text to type"),
                 Property(name: "submit", type: "boolean",
                          description: "press Enter after typing (default false)"),
                 browserProp, debugPortProp, relaunchProp,
             ],
             required: ["selector", "text", "browser"]),

        Tool(name: "web_select",
             description: "Choose a <select> dropdown option by its value OR visible text "
                 + "(CDP only), then read the selected option back. Verified only when the "
                 + "read-back matches; refuses if the target isn't a <select> or no option "
                 + "matches (lists the real options). Accepts an @eN ref or a CSS selector.",
             properties: [
                 Property(name: "selector", type: "string",
                          description: "an @eN ref or CSS selector for the <select>"),
                 Property(name: "value", type: "string",
                          description: "the option's value or visible text to choose"),
                 browserProp, debugPortProp, relaunchProp,
             ],
             required: ["selector", "value", "browser"]),

        Tool(name: "web_html",
             description: "Read a CSS-selected element's outerHTML + attributes + key computed "
                 + "styles (CDP only). Pure read.",
             properties: [
                 Property(name: "selector", type: "string",
                          description: "a CSS selector for the element"),
                 browserProp, debugPortProp, relaunchProp,
             ],
             required: ["selector", "browser"]),

        Tool(name: "web_eval",
             description: "Evaluate a JavaScript expression in the page and return its "
                 + "stringified value (CDP only). Pure read.",
             properties: [
                 Property(name: "js", type: "string",
                          description: "the JavaScript expression to evaluate"),
                 browserProp, debugPortProp, relaunchProp,
             ],
             required: ["js", "browser"]),
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
