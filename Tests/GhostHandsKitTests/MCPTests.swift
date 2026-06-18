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

    func testToolsListAdvertisesAllEightVerbs() {
        let req = JSONRPCFraming.decodeLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)!
        guard case let .respond(resp) = MCPProtocol.route(req) else {
            return XCTFail("tools/list should respond")
        }
        let tools = resp["result"]?["tools"]?.arrayValue ?? []
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names),
                       ["click", "type", "set_value", "doubleclick", "act",
                        "snapshot", "find", "shot"])
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
