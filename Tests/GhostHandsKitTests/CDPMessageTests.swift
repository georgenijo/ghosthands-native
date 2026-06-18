import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE request encode + the id-match classifier (the heart of a
/// CDP call), over FABRICATED text frames. No socket. Ports the classifier half
/// of the Python `test_cdp_call_*` cases: our-reply matches, a foreign event is
/// skipped, a foreign-id reply is skipped, an error reply surfaces its message.
final class CDPMessageTests: XCTestCase {
    /// A request round-trips: id, method, and params survive encode → decode.
    func testEncodeRequestRoundTrips() throws {
        let data = try CDPMessage.encodeRequest(
            id: 1, method: "Runtime.evaluate", params: ["expression": "40+2"])
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? Int, 1)
        XCTAssertEqual(obj["method"] as? String, "Runtime.evaluate")
        let params = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["expression"] as? String, "40+2")
    }

    /// A reply whose id matches what we await classifies as `.reply` and carries
    /// the result payload.
    func testClassifyMatchesOurReply() {
        let frame = CDPMessage.classify(#"{"id":1,"result":{"value":42}}"#, expecting: 1)
        guard case let .reply(id, result) = frame else {
            return XCTFail("expected .reply, got \(frame)")
        }
        XCTAssertEqual(id, 1)
        XCTAssertEqual((result?["value"] as? NSNumber)?.intValue, 42)
    }

    /// A foreign EVENT (`{"method":…}`, no matching id) is the skip signal; a
    /// reply for a DIFFERENT id is NOT our reply and is also skipped.
    func testClassifySkipsForeignEvent() {
        let event = CDPMessage.classify(
            #"{"method":"Network.requestWillBeSent","params":{"x":1}}"#, expecting: 1)
        guard case .event = event else { return XCTFail("expected .event, got \(event)") }

        let foreignReply = CDPMessage.classify(#"{"id":999,"result":{}}"#, expecting: 1)
        XCTAssertNotEqual(foreignReply, .reply(id: 1, result: nil),
                          "a foreign-id reply must NOT classify as our reply")
        // It is skipped (modelled as an event so the loop `continue`s).
        guard case .event = foreignReply else {
            return XCTFail("expected foreign-id reply to be skipped (.event), got \(foreignReply)")
        }
    }

    /// An error reply for our id surfaces the CDP error message. Port of
    /// `test_cdp_call_error_reply_raises`.
    func testClassifySurfacesErrorReply() {
        let frame = CDPMessage.classify(
            #"{"id":1,"error":{"code":-32000,"message":"boom"}}"#, expecting: 1)
        guard case let .errorReply(id, message) = frame else {
            return XCTFail("expected .errorReply, got \(frame)")
        }
        XCTAssertEqual(id, 1)
        XCTAssertEqual(message, "boom")
    }

    /// Un-decodable junk classifies as `.other` (skipped), never crashes.
    func testClassifyJunkIsOther() {
        XCTAssertEqual(CDPMessage.classify("not json at all", expecting: 1), .other)
    }
}
