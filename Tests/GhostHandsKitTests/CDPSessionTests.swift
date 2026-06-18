import XCTest
@testable import GhostHandsKit

/// Hermetic — the deadline-loop over a FAKE transport replaying crafted frames.
/// NO real socket, NO browser. Ports `test_cdp_call_matches_id_and_skips_event`
/// + `test_cdp_call_deadline_raises_not_loops` at the message granularity (the
/// RFC 6455 frame tests evaporate — URLSession owns framing).
final class CDPSessionTests: XCTestCase {
    /// Replays a scripted `[String]` from `receive()` (one message per call). When
    /// `endless` is true, the LAST frame repeats forever, so ONLY the deadline can
    /// stop the loop (ports the Python `_FakeSocket(repeat_last=True)`). Records
    /// every `send`. An `actor` so concurrent send/receive can't race the index.
    actor FakeTransport: WebSocketTransport {
        private let frames: [String]
        private let endless: Bool
        private var index = 0
        private(set) var sent: [String] = []

        init(frames: [String], endless: Bool = false) {
            self.frames = frames
            self.endless = endless
        }

        func send(_ text: String) async throws { sent.append(text) }

        func receive() async throws -> String {
            if index < frames.count {
                let f = frames[index]
                index += 1
                return f
            }
            if endless, let last = frames.last { return last }
            // Exhausted, non-endless: a never-arriving reply (the loop must hit
            // its deadline). Yield so we don't spin a tight CPU loop in the test.
            await Task.yield()
            // Return an inert event so the classifier skips it and re-checks the
            // deadline (no message ever satisfies the awaited id).
            return #"{"method":"Inert.tick"}"#
        }

        var sentCount: Int { sent.count }
        var firstSent: String? { sent.first }
    }

    /// A foreign event before our reply is skipped; the matching reply returns.
    /// Exactly ONE send happens and its JSON carries id==1 + the method. Direct
    /// port of `test_cdp_call_matches_id_and_skips_event`.
    func testCallMatchesIdSkipsEvent() async throws {
        let transport = FakeTransport(frames: [
            #"{"method":"Network.requestWillBeSent","params":{}}"#,
            #"{"id":1,"result":{"value":42}}"#,
        ])
        let session = CDPSession(transport: transport)
        let result = try await session.call(
            "Runtime.evaluate", params: ["expression": "40+2"])
        XCTAssertEqual((result["value"] as? NSNumber)?.intValue, 42)

        let sentCount = await transport.sentCount
        XCTAssertEqual(sentCount, 1, "exactly one request should be sent")
        let firstSent = await transport.firstSent
        let sent = try XCTUnwrap(firstSent)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        XCTAssertEqual(obj["id"] as? Int, 1, "first call's id is 1 (pre-increment from 0)")
        XCTAssertEqual(obj["method"] as? String, "Runtime.evaluate")
    }

    /// THE critical test: an ENDLESS foreign-id reply stream never satisfies our
    /// awaited id, so the deadline must STOP the loop (raise), not hang. The
    /// elapsed wall-clock is bounded. Port of
    /// `test_cdp_call_deadline_raises_not_loops`.
    func testDeadlineRaisesNotLoops() async throws {
        let transport = FakeTransport(frames: [#"{"id":999,"result":{}}"#], endless: true)
        let session = CDPSession(transport: transport)

        let start = ContinuousClock.now
        do {
            _ = try await session.call("Runtime.evaluate", deadline: .milliseconds(50))
            XCTFail("expected the deadline to raise")
        } catch let GhostHandsError.cdpTransport(reason) {
            XCTAssertTrue(reason.contains("no response"),
                          "deadline error should say 'no response', got: \(reason)")
        }
        let elapsed = ContinuousClock.now - start
        // The loop is bounded by the deadline — generously under a couple seconds
        // proves it did not spin forever.
        XCTAssertLessThan(elapsed, .seconds(2), "deadline must stop the loop promptly")
    }

    /// An error reply for our id throws `cdpTransport` carrying the message.
    func testErrorReplyThrows() async throws {
        let transport = FakeTransport(frames: [#"{"id":1,"error":{"message":"boom"}}"#])
        let session = CDPSession(transport: transport)
        do {
            _ = try await session.call("Runtime.evaluate")
            XCTFail("expected an error reply to throw")
        } catch let GhostHandsError.cdpTransport(reason) {
            XCTAssertTrue(reason.contains("boom"), "error message should surface, got: \(reason)")
        }
    }

    /// The SECURITY guard fires at construction: a non-loopback
    /// `webSocketDebuggerUrl` throws WITHOUT ever creating a transport/socket.
    func testNonLoopbackRefusedBeforeSocket() {
        XCTAssertThrowsError(try CDPSession.open(wsURL: "ws://evil.com:9222/x")) { error in
            guard case let GhostHandsError.cdpTransport(reason) = error else {
                return XCTFail("expected cdpTransport, got \(error)")
            }
            XCTAssertTrue(reason.contains("non-loopback"),
                          "refusal should name the non-loopback cause, got: \(reason)")
        }
    }

    /// A loopback url is accepted by the guard (it constructs a session; no socket
    /// IO happens until the first `call`, which this test does NOT issue).
    func testLoopbackAcceptedByGuard() throws {
        XCTAssertNoThrow(try CDPSession.open(
            wsURL: "ws://127.0.0.1:9222/devtools/browser/abc"))
    }
}
