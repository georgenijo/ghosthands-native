import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE MCP layer: JSON-RPC framing, request parsing, response
/// building, the tool registry/schemas, and the verified/dispatched-unverified/
/// refuse honesty mapping. Driven entirely on FABRICATED request strings and
/// FABRICATED Outcome values — NEVER starts a server, NEVER drives a live app.
///
/// The cardinal assertion this file pins: a dispatched-UNVERIFIED outcome
/// (`verified == false`) must NEVER map to a success-claiming text, and a thrown
/// `GhostHandsError` must map to an isError:true tool result (not a protocol
/// error, not a silent success).
final class MCPTests: XCTestCase {

    // MARK: - Framing (newline-delimited JSON)

    func testDecodeLineParsesOneObject() {
        let v = JSONRPCFraming.decodeLine(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(v?["method"]?.stringValue, "ping")
        XCTAssertEqual(v?["id"], .number(1))
    }

    func testDecodeLineTolerationOfBlankLines() {
        XCTAssertNil(JSONRPCFraming.decodeLine(""))
        XCTAssertNil(JSONRPCFraming.decodeLine("   \n"))
    }

    func testDecodeLineMalformedReturnsNil() {
        XCTAssertNil(JSONRPCFraming.decodeLine("{not json"))
    }

    func testEncodeLineHasNoEmbeddedNewline() {
        let v = JSONRPCResponse.success(id: .number(7), result: .object([
            "content": .array([.object(["type": .string("text"),
                                        "text": .string("a\tb")])]),
        ]))
        let line = JSONRPCFraming.encodeLine(v)
        XCTAssertFalse(line.contains("\n"), "a compact JSON-RPC line must be single-line")
        // Round-trips back to the same value.
        XCTAssertEqual(JSONRPCFraming.decodeLine(line)?["id"], .number(7))
    }

    func testIntegerIdsRoundTripAsIntegers() {
        let line = JSONRPCFraming.encodeLine(JSONRPCResponse.success(
            id: .number(42), result: .object([:])))
        XCTAssertTrue(line.contains("\"id\":42"), "id should serialise as 42 not 42.0: \(line)")
    }

    func testStringIdsArePreserved() {
        let req = JSONRPCFraming.decodeLine(#"{"jsonrpc":"2.0","id":"abc","method":"x"}"#)!
        guard case let .success(parsed) = JSONRPCRequest.parse(req) else {
            return XCTFail("should parse")
        }
        XCTAssertEqual(parsed.id, .string("abc"))
    }

    // MARK: - Request parsing

    func testNotificationHasNoId() {
        let v = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)!
        guard case let .success(req) = JSONRPCRequest.parse(v) else {
            return XCTFail("should parse")
        }
        XCTAssertTrue(req.isNotification)
        XCTAssertNil(req.id)
    }

    func testParseRejectsNonObject() {
        XCTAssertEqual(JSONRPCRequest.parse(.array([])), .failure(.notAnObject))
    }

    func testParseRejectsMissingMethod() {
        XCTAssertEqual(JSONRPCRequest.parse(.object(["id": .number(1)])),
                       .failure(.missingMethod))
    }

    // MARK: - initialize

    func testInitializeAdvertisesVersionToolsAndServerInfo() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)!
        guard case let .respond(resp) = MCPProtocol.route(req) else {
            return XCTFail("initialize should respond")
        }
        let result = resp["result"]
        XCTAssertEqual(result?["protocolVersion"]?.stringValue, MCPProtocol.protocolVersion)
        XCTAssertEqual(result?["serverInfo"]?["name"]?.stringValue, "ghosthands-mcp")
        XCTAssertEqual(result?["serverInfo"]?["version"]?.stringValue, GhostHands.version)
        XCTAssertNotNil(result?["capabilities"]?["tools"], "must advertise tools capability")
    }

    func testInitializedNotificationIsIgnored() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)!
        XCTAssertEqual(MCPProtocol.route(req), .ignore)
    }

    // MARK: - tools/list

    /// The CANONICAL interactive-actuation/observation surface — every CLI verb a
    /// remote brain drives a live UI with, exposed over MCP. This is the contract
    /// the surface-exposure work must hold: each name appears once, the early 8 are
    /// still present, and the 31-tool surface is complete.
    ///
    /// DELIBERATELY OMITTED (not part of this set, and that is honest, not a gap):
    /// the CLI's `click-at` (raw-pixel click — MCP exposes only named-control act),
    /// and `replay`/`record` (trajectory file capture/playback — a local-runner
    /// concern, not a remote per-call verb). Compound CLI verbs are split into
    /// per-tool names here (`web`→6, `window`→3, `clipboard`→2), so the tool count
    /// is higher than the CLI's top-level verb count by design.
    static let expectedToolNames: Set<String> = [
        // the early 8 (unchanged)
        "click", "type", "set_value", "doubleclick", "act", "snapshot", "find", "shot",
        // act tier (named control)
        "focus", "right_click", "scroll", "drag", "menu",
        // read + checked tiers
        "extract", "dialog", "wait", "assert", "apps", "ocr", "see",
        // system tier
        "clipboard_read", "clipboard_write", "navigate", "key", "install",
        // windows
        "windows", "window_move", "window_resize", "window_raise",
        // web
        "web_read", "web_tabs", "web_click", "web_fill", "web_type", "web_key",
        "web_select", "web_html", "web_eval",
    ]

    func testToolsListAdvertisesTheFullVerbSurface() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)!
        guard case let .respond(resp) = MCPProtocol.route(req) else {
            return XCTFail("tools/list should respond")
        }
        let tools = resp["result"]?["tools"]?.arrayValue ?? []
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names), MCPTests.expectedToolNames)
        // No tool advertised twice.
        XCTAssertEqual(names.count, Set(names).count, "duplicate tool name advertised")
    }

    /// EVERY advertised tool carries a non-empty description and a well-formed
    /// object inputSchema whose `required` keys all appear in `properties`. This
    /// pins the surface-exposure quality bar for every NEW tool at once.
    func testEveryToolHasDescriptionAndConsistentSchema() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)!
        guard case let .respond(resp) = MCPProtocol.route(req) else {
            return XCTFail("tools/list should respond")
        }
        let tools = resp["result"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.count, MCPTests.expectedToolNames.count)
        for tool in tools {
            let name = tool["name"]?.stringValue ?? "(unnamed)"
            let desc = tool["description"]?.stringValue ?? ""
            XCTAssertFalse(desc.isEmpty, "\(name) must carry a non-empty description")
            let schema = tool["inputSchema"]
            XCTAssertEqual(schema?["type"]?.stringValue, "object", "\(name) schema type")
            let props = schema?["properties"]?.objectValue ?? [:]
            let required = (schema?["required"]?.arrayValue ?? []).compactMap { $0.stringValue }
            for key in required {
                XCTAssertNotNil(props[key],
                                "\(name): required key \(key) must be in properties")
                // Each required property declares a JSON type.
                XCTAssertNotNil(props[key]?["type"]?.stringValue,
                                "\(name).\(key) must declare a type")
            }
        }
    }

    /// Spot-check the typed (non-string) params on the new tools so the schema
    /// genuinely carries numbers/booleans/integers, not everything-as-string.
    func testTypedParamsAreAdvertisedWithTheirJSONType() {
        func paramType(_ tool: String, _ prop: String) -> String? {
            let json = MCPTools.json(for: MCPTools.tool(named: tool)!)
            return json["inputSchema"]?["properties"]?[prop]?["type"]?.stringValue
        }
        XCTAssertEqual(paramType("window_move", "x"), "number")
        XCTAssertEqual(paramType("window_move", "y"), "number")
        XCTAssertEqual(paramType("window_resize", "w"), "number")
        XCTAssertEqual(paramType("scroll", "amount"), "number")
        XCTAssertEqual(paramType("wait", "gone"), "boolean")
        XCTAssertEqual(paramType("wait", "timeout"), "number")
        XCTAssertEqual(paramType("install", "force"), "boolean")
        XCTAssertEqual(paramType("right_click", "visible"), "boolean")
        XCTAssertEqual(paramType("web_read", "debugPort"), "integer")
        XCTAssertEqual(paramType("web_read", "cdp"), "boolean")
        XCTAssertEqual(paramType("web_read", "relaunch"), "boolean")
    }

    /// The assert tool advertises its kind enum (exists/absent/value/count).
    func testAssertSchemaExposesKindEnum() {
        let json = MCPTools.json(for: MCPTools.tool(named: "assert")!)
        let kindEnum = json["inputSchema"]?["properties"]?["kind"]?["enum"]?.arrayValue
        XCTAssertEqual(kindEnum, ["exists", "absent", "value", "count"].map { .string($0) })
    }

    /// The scroll tool advertises its direction enum.
    func testScrollSchemaExposesDirectionEnum() {
        let json = MCPTools.json(for: MCPTools.tool(named: "scroll")!)
        let dirEnum = json["inputSchema"]?["properties"]?["direction"]?["enum"]?.arrayValue
        XCTAssertEqual(dirEnum, ["up", "down", "left", "right"].map { .string($0) })
    }

    func testEveryToolNameMatchesMCPNamePattern() {
        let pattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$")
        for t in MCPTools.all {
            let r = NSRange(t.name.startIndex..., in: t.name)
            XCTAssertNotNil(pattern.firstMatch(in: t.name, range: r),
                            "\(t.name) must match the MCP tool-name pattern")
        }
    }

    func testToolSchemaCarriesPropertiesAndRequired() {
        let clickJSON = MCPTools.json(for: MCPTools.tool(named: "click")!)
        let schema = clickJSON["inputSchema"]
        XCTAssertEqual(schema?["type"]?.stringValue, "object")
        XCTAssertNotNil(schema?["properties"]?["name"])
        XCTAssertNotNil(schema?["properties"]?["app"])
        XCTAssertEqual(schema?["required"]?.arrayValue,
                       [.string("name"), .string("app")])
    }

    func testActSchemaExposesActionEnum() {
        let actJSON = MCPTools.json(for: MCPTools.tool(named: "act")!)
        let actionEnum = actJSON["inputSchema"]?["properties"]?["action"]?["enum"]?.arrayValue
        XCTAssertEqual(actionEnum,
                       ["open", "confirm", "pick", "show-menu", "cancel",
                        "raise", "increment", "decrement"].map { .string($0) })
    }

    // MARK: - tools/call routing (front half — validation, no AX)

    func testToolsCallWithValidArgsRequestsDispatch() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"name":"OK","app":"Finder"}}}"#)!
        guard case let .dispatchTool(id, name, args) = MCPProtocol.route(req) else {
            return XCTFail("valid tools/call should request dispatch")
        }
        XCTAssertEqual(id, .number(3))
        XCTAssertEqual(name, "click")
        XCTAssertEqual(MCPProtocol.string("app", from: args), "Finder")
    }

    func testToolsCallUnknownToolIsErrorResultNotProtocolError() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"frobnicate","arguments":{}}}"#)!
        guard case let .respond(resp) = MCPProtocol.route(req) else {
            return XCTFail("unknown tool should respond, not dispatch")
        }
        // It is a SUCCESS envelope (no top-level error) whose tool result isError.
        XCTAssertNil(resp["error"])
        XCTAssertEqual(resp["result"]?["isError"], .bool(true))
    }

    func testToolsCallMissingRequiredArgIsErrorResult() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"app":"Finder"}}}"#)!
        guard case let .respond(resp) = MCPProtocol.route(req) else {
            return XCTFail("missing arg should respond with an error result")
        }
        XCTAssertEqual(resp["result"]?["isError"], .bool(true))
        XCTAssertNil(resp["error"], "a missing arg is a tool error, not a protocol fault")
    }

    func testFirstMissingRequiredPinpointsTheArg() {
        let tool = MCPTools.tool(named: "type")!
        let args: JSONValue = .object(["text": .string("hi"), "field": .string("Search")])
        XCTAssertEqual(MCPProtocol.firstMissingRequired(tool: tool, arguments: args), "app")
    }

    func testEmptyStringArgCountsAsMissing() {
        let tool = MCPTools.tool(named: "click")!
        let args: JSONValue = .object(["name": .string(""), "app": .string("Finder")])
        XCTAssertEqual(MCPProtocol.firstMissingRequired(tool: tool, arguments: args), "name")
    }

    // MARK: - typed-arg routing (number / boolean required args)

    /// A required NUMBER arg (window_move x/y) validates as a JSON number — it must
    /// NOT be forced through the string check (a number is not a non-empty string).
    func testNumericRequiredArgValidatesAndDispatches() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"window_move","arguments":{"x":100,"y":200,"app":"Finder"}}}"#)!
        guard case let .dispatchTool(id, name, args) = MCPProtocol.route(req) else {
            return XCTFail("a numeric-arg tools/call should dispatch, not error")
        }
        XCTAssertEqual(id, .number(4))
        XCTAssertEqual(name, "window_move")
        XCTAssertEqual(MCPProtocol.number("x", from: args), 100)
        XCTAssertEqual(MCPProtocol.number("y", from: args), 200)
    }

    /// A missing required NUMBER arg is pinpointed (and is NOT silently coerced to 0).
    func testMissingNumericRequiredArgIsPinpointed() {
        let tool = MCPTools.tool(named: "window_move")!
        let args: JSONValue = .object(["x": .number(100), "app": .string("Finder")])
        XCTAssertEqual(MCPProtocol.firstMissingRequired(tool: tool, arguments: args), "y")
    }

    /// A number supplied where a STRING is required does NOT satisfy it (a stray
    /// number for `name` is still "missing" — never coerced to a label).
    func testNumberDoesNotSatisfyAStringRequiredArg() {
        let tool = MCPTools.tool(named: "click")!
        let args: JSONValue = .object(["name": .number(7), "app": .string("Finder")])
        XCTAssertEqual(MCPProtocol.firstMissingRequired(tool: tool, arguments: args), "name")
    }

    /// The opt-in boolean flags default FALSE (the invisible / non-relaunch
    /// defaults), and a present bool is read through.
    func testBoolFlagDefaultsFalseAndReadsThrough() {
        let args: JSONValue = .object(["visible": .bool(true)])
        XCTAssertTrue(MCPProtocol.bool("visible", from: args))
        XCTAssertFalse(MCPProtocol.bool("relaunch", from: args), "absent ⇒ default false")
        XCTAssertFalse(MCPProtocol.bool("missing", from: .object([:])))
    }

    /// The integer reader floors a JSON number; absent ⇒ nil (the caller then uses
    /// the verb's own default, e.g. debugPort 9222).
    func testIntReaderAndDefaultPort() {
        let args: JSONValue = .object(["debugPort": .number(9333)])
        XCTAssertEqual(MCPProtocol.int("debugPort", from: args), 9333)
        XCTAssertNil(MCPProtocol.int("debugPort", from: .object([:])))
    }

    /// EVERY advertised tool routes to a dispatch (not an unknown-tool error) when
    /// fed a fabricated, schema-satisfying argument set — proving the tool-name →
    /// verb wiring exists for the whole surface. (No AX runs: routing stops at
    /// `.dispatchTool`, which is the PURE front half.)
    func testEveryToolNameRoutesToDispatchWithValidArgs() {
        for tool in MCPTools.all {
            let args = MCPTests.fabricatedArgs(for: tool)
            let call: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(1),
                "method": .string("tools/call"),
                "params": .object(["name": .string(tool.name), "arguments": args]),
            ])
            switch MCPProtocol.route(call) {
            case let .dispatchTool(_, name, _):
                XCTAssertEqual(name, tool.name)
            case let .respond(resp):
                XCTFail("\(tool.name) should dispatch with valid args, got: "
                    + "\(resp["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "?")")
            case .ignore:
                XCTFail("\(tool.name) should not be ignored")
            }
        }
    }

    /// Build a schema-satisfying argument object for a tool: each required prop
    /// gets a value of its declared type. PURE fabrication — never touches AX.
    static func fabricatedArgs(for tool: MCPTools.Tool) -> JSONValue {
        var obj: [String: JSONValue] = [:]
        for key in tool.required {
            let type = tool.properties.first { $0.name == key }?.type ?? "string"
            switch type {
            case "number", "integer": obj[key] = .number(1)
            case "boolean": obj[key] = .bool(true)
            default:
                // Use an enum value when the prop constrains one, else a placeholder.
                let prop = tool.properties.first { $0.name == key }
                obj[key] = .string(prop?.enumValues.first ?? "X")
            }
        }
        return .object(obj)
    }

    // MARK: - unknown method / protocol errors

    func testUnknownRequestMethodIsMethodNotFound() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":9,"method":"does/not/exist","params":{}}"#)!
        guard case let .respond(resp) = MCPProtocol.route(req) else {
            return XCTFail("unknown method should respond")
        }
        XCTAssertEqual(resp["error"]?["code"], .number(Double(JSONRPCError.methodNotFound)))
    }

    func testUnknownNotificationIsIgnored() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#)!
        XCTAssertEqual(MCPProtocol.route(req), .ignore)
    }

    func testMalformedObjectRoutesToInvalidRequest() {
        guard case let .respond(resp) = MCPProtocol.route(.array([])) else {
            return XCTFail("non-object should respond with an error")
        }
        XCTAssertEqual(resp["error"]?["code"], .number(Double(JSONRPCError.invalidRequest)))
    }

    // MARK: - Honesty mapping: VERIFIED

    func testVerifiedClickMapsToVerifiedTextNotError() {
        let o = ClickOutcome(app: "Finder", name: "New Folder", role: "AXButton",
                             axAccepted: true, verified: true,
                             evidence: "display 0 → 1", valueBefore: "0", valueAfter: "1")
        let r = MCPMapping.map(o)
        XCTAssertEqual(r["isError"], .bool(false))
        let text = r["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("verified"), text)
        XCTAssertTrue(text.contains("display 0 → 1"), text)
        XCTAssertEqual(r["structuredContent"]?["verified"], .bool(true))
    }

    // MARK: - Honesty mapping: DISPATCHED-UNVERIFIED (the cardinal sin guard)

    func testUnverifiedClickSaysUnverifiedNeverSuccess() {
        let o = ClickOutcome(app: "Finder", name: "Ghost", role: "AXButton",
                             axAccepted: true, verified: false, evidence: nil,
                             valueBefore: nil, valueAfter: nil)
        let r = MCPMapping.map(o)
        XCTAssertEqual(r["isError"], .bool(false), "dispatch is not a refuse")
        let text = (r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "").lowercased()
        XCTAssertTrue(text.contains("unverified"), "must state unverified: \(text)")
        XCTAssertFalse(text.contains("verified:"), "must NOT claim 'verified:' on a dispatch")
        XCTAssertEqual(r["structuredContent"]?["verified"], .bool(false))
    }

    func testUnverifiedValueSetSaysUnverifiedNeverSuccess() {
        // The M3 cardinal sin: AX accepted the set but read-back unchanged.
        let o = ValueOutcome(app: "Notes", name: "Title", role: "AXTextField",
                             verb: "set", intended: "hello", axAccepted: true,
                             verified: false, exact: false,
                             valueBefore: "old", valueAfter: "old", evidence: nil)
        let r = MCPMapping.map(o)
        XCTAssertEqual(r["isError"], .bool(false))
        let text = (r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "").lowercased()
        XCTAssertTrue(text.contains("unverified"), text)
        XCTAssertEqual(r["structuredContent"]?["verified"], .bool(false))
    }

    func testVerifiedValueSetQuotesEvidence() {
        let o = ValueOutcome(app: "Notes", name: "Title", role: "AXTextField",
                             verb: "typed", intended: "hello", axAccepted: true,
                             verified: true, exact: true,
                             valueBefore: "", valueAfter: "hello", evidence: "→ \"hello\"")
        let r = MCPMapping.map(o)
        XCTAssertEqual(r["isError"], .bool(false))
        let text = r["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("verified"), text)
    }

    func testUnverifiedActSaysUnverified() {
        let o = ActOutcome(app: "System Settings", name: "Volume", role: "AXSlider",
                           action: "AXIncrement", verbLabel: "act increment",
                           axAccepted: true, verified: false, evidence: nil)
        let r = MCPMapping.map(o)
        let text = (r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "").lowercased()
        XCTAssertEqual(r["isError"], .bool(false))
        XCTAssertTrue(text.contains("unverified"), text)
    }

    // MARK: - Auditability: the RAW AX action is in the structured side-channel

    func testActStructuredChannelSurfacesRawAXAction() {
        // A brain reading ONLY structuredContent must see WHICH AX action ran,
        // matching the human text — never just the friendly verb label.
        let o = ActOutcome(app: "Finder", name: "File", role: "AXMenuButton",
                           action: "AXShowMenu", verbLabel: "act show-menu",
                           axAccepted: true, verified: false, evidence: nil)
        let r = MCPMapping.map(o)
        XCTAssertEqual(r["structuredContent"]?["action"], .string("AXShowMenu"))
    }

    func testClickStructuredChannelReportsAXPress() {
        let o = ClickOutcome(app: "Finder", name: "OK", role: "AXButton",
                             axAccepted: true, verified: false, evidence: nil,
                             valueBefore: nil, valueAfter: nil)
        let r = MCPMapping.map(o)
        XCTAssertEqual(r["structuredContent"]?["action"], .string("AXPress"))
    }

    // MARK: - Honesty mapping: REFUSE (thrown GhostHandsError → isError:true)

    func testRefuseMapsToIsErrorWithHonestMessage() {
        let err = GhostHandsError.elementNotFound(name: "Frobnicate", app: "Finder")
        let r = MCPMapping.refuse(err)
        XCTAssertEqual(r["isError"], .bool(true))
        let text = r["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertEqual(text, err.description)
        XCTAssertTrue(text.contains("Frobnicate"))
    }

    func testSecureFieldRefuseIsError() {
        let err = GhostHandsError.secureFieldUnverifiable(name: "Password")
        let r = MCPMapping.refuse(err)
        XCTAssertEqual(r["isError"], .bool(true))
        XCTAssertTrue((r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
            .contains("secure text field"))
    }

    func testAllErrorCasesProduceNonEmptyHonestText() {
        let cases: [GhostHandsError] = [
            .accessibilityNotTrusted,
            .appNotFound("X"),
            .appAmbiguous(spec: "S", candidates: ["a", "b"]),
            .elementNotFound(name: "n", app: "a"),
            .ambiguousMatch(name: "n", candidates: ["a", "b"]),
            .locatorIndexOutOfRange(name: "n", requested: 5, count: 2),
            .actionRejected(name: "n", action: "AXPress"),
            .secureFieldUnverifiable(name: "n"),
            .valueUncoercible(value: "v", role: "AXSlider"),
            .wrongActionForControl(name: "n", action: "open", supported: ["AXPress"]),
            .unknownAction("zap"),
            .valueUnchanged(name: "n", value: "v"),
            .screenRecordingNotTrusted,
            .noWindows(app: "a"),
            .captureFailed(reason: "occluded"),
        ]
        for err in cases {
            let r = MCPMapping.refuse(err)
            XCTAssertEqual(r["isError"], .bool(true), "\(err)")
            let text = r["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            XCTAssertFalse(text.isEmpty, "\(err) must carry a one-line message")
        }
    }

    // MARK: - The JSONResult-envelope bridge (the new surface's honesty boundary)

    /// A `refused` envelope (a thrown GhostHandsError, shaped by the SAME
    /// JSONShape.fromRefusal the CLI uses) → isError:true, carrying the honest
    /// message. This is the cardinal rule for the new surface: refuse → isError,
    /// NEVER a fake ok.
    func testEnvelopeRefusedMapsToIsError() {
        let env = JSONResult.fromRefusal(
            verb: "scroll",
            message: GhostHandsError.noScrollArea(app: "Finder", named: nil).description,
            app: "Finder")
        let r = MCPMapping.fromEnvelope(env)
        XCTAssertEqual(r["isError"], .bool(true), "a refused envelope must be an isError result")
        let text = r["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("no scroll area"), text)
        // The structured side-channel carries the SAME refused status + error.
        XCTAssertEqual(r["structuredContent"]?["status"], .string("refused"))
        XCTAssertNotNil(r["structuredContent"]?["error"])
    }

    /// A `dispatched` envelope (acted, no observed proof) → isError:false, and the
    /// structured status stays "dispatched" — NEVER upgraded to verified, NEVER an
    /// error. The cardinal sin guard, applied to the envelope bridge.
    func testEnvelopeDispatchedIsNotErrorAndNotUpgraded() {
        // A scroll that AX-accepted but did not move the bar → dispatched.
        let o = ScrollOutcome(
            app: "Finder", container: "AXScrollArea", direction: .down, amount: 1,
            via: "AX scroll bar", dispatched: true, verified: false, observable: true,
            positionBefore: 0.5, positionAfter: 0.5, mode: .invisible)
        let r = MCPMapping.fromEnvelope(.fromScroll(o))
        XCTAssertEqual(r["isError"], .bool(false), "dispatch is not a refuse")
        XCTAssertEqual(r["structuredContent"]?["status"], .string("dispatched"))
        XCTAssertNil(r["structuredContent"]?["evidence"], "no evidence on a dispatch")
    }

    /// A `verified` envelope → isError:false, status "verified", and the OBSERVED
    /// evidence rides through to the structured channel verbatim.
    func testEnvelopeVerifiedCarriesEvidence() {
        let o = ScrollOutcome(
            app: "Finder", container: "AXScrollArea", direction: .down, amount: 1,
            via: "AX scroll bar", dispatched: true, verified: true, observable: true,
            positionBefore: 0.1, positionAfter: 0.6, mode: .invisible)
        let r = MCPMapping.fromEnvelope(.fromScroll(o))
        XCTAssertEqual(r["isError"], .bool(false))
        XCTAssertEqual(r["structuredContent"]?["status"], .string("verified"))
        XCTAssertNotNil(r["structuredContent"]?["evidence"])
        XCTAssertTrue((r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
            .contains("verified"))
    }

    /// An assert `fail` (CHECKED, did not hold) is a CLEAN result (isError:false) —
    /// the assertion was answered honestly, NOT a protocol/refuse error. Mirrors
    /// the CLI's exit-1 (fail) vs exit-2 (refuse) split.
    func testEnvelopeAssertFailIsCleanResultNotError() {
        let o = GhostHands.AssertOutcome(
            app: "Finder", name: "Trash",
            verdict: .fail("FAIL: expected count 2, observed 1"),
            observed: .present(count: 1, value: nil))
        let r = MCPMapping.fromEnvelope(.fromAssert(o))
        XCTAssertEqual(r["isError"], .bool(false), "a FAIL is a checked verdict, not an error")
        XCTAssertEqual(r["structuredContent"]?["status"], .string("fail"))
    }

    /// An assert `pass` → isError:false, status "pass".
    func testEnvelopeAssertPassIsOk() {
        let o = GhostHands.AssertOutcome(
            app: "Finder", name: "Trash",
            verdict: .pass("PASS: exists"),
            observed: .present(count: 1, value: nil))
        let r = MCPMapping.fromEnvelope(.fromAssert(o))
        XCTAssertEqual(r["isError"], .bool(false))
        XCTAssertEqual(r["structuredContent"]?["status"], .string("pass"))
    }

    /// A pure-read `ok` envelope (windows) → isError:false, status "ok", and the
    /// read payload rides in the structured fields.
    func testEnvelopeReadOkCarriesFields() {
        let r = MCPMapping.fromEnvelope(.fromWindows(
            WindowsResult(app: "Finder", windows: [])))
        XCTAssertEqual(r["isError"], .bool(false))
        XCTAssertEqual(r["structuredContent"]?["status"], .string("ok"))
        XCTAssertEqual(r["structuredContent"]?["verb"], .string("windows"))
        XCTAssertNotNil(r["structuredContent"]?["fields"]?["count"])
    }

    /// The structured content is the SAME envelope the CLI `--json` emits: the
    /// bridge must round-trip every status faithfully (verb + status preserved)
    /// and only the refused arm flips isError.
    func testEnvelopeBridgePreservesStatusAcrossAllArms() {
        let cases: [(JSONResult, expectError: Bool, status: String)] = [
            (.fromWindowRaise(WindowRaiseOutcome(
                app: "Finder", windowTitle: "w", windowID: nil,
                axAccepted: true, verified: false)), false, "dispatched"),
            (.fromClipboardRead("hello"), false, "ok"),
            (.fromRefusal(verb: "key", message: "unknown key"), true, "refused"),
        ]
        for (env, expectError, status) in cases {
            let r = MCPMapping.fromEnvelope(env)
            XCTAssertEqual(r["isError"], .bool(expectError), "isError for \(status)")
            XCTAssertEqual(r["structuredContent"]?["status"], .string(status))
        }
    }

    // MARK: - Read-tier mapping (find: not-found is a clean result, not a refuse)

    func testFindNotFoundIsCleanResult() {
        let o = GhostHands.FindOutcome(app: "Finder", query: "ghost", hits: [])
        let r = MCPMapping.map(o)
        XCTAssertEqual(r["isError"], .bool(false), "not-found is a successful probe")
        XCTAssertTrue((r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
            .contains("not found"))
    }

    func testFindFoundReportsHits() {
        let facts = ElementFacts(role: "AXButton", title: "7", supportsPress: true)
        let o = GhostHands.FindOutcome(app: "Calculator", query: "7", hits: [facts])
        let r = MCPMapping.map(o)
        XCTAssertEqual(r["isError"], .bool(false))
        XCTAssertTrue((r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
            .contains("found"))
    }
}
