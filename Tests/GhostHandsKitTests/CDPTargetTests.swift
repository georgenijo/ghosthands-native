import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE `/json/list` decode + filter and the loopback security
/// guard, over FABRICATED bytes. No live browser, no real socket. Ports
/// `test_list_targets_filters_to_pages` / `_malformed_json_raises` and the
/// loopback rail from the Python web tier's offline layer.
final class CDPTargetTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    /// A `service_worker` is dropped; a page with no explicit `type` is KEPT
    /// (missing type defaults to "page"). Direct port of
    /// `test_list_targets_filters_to_pages`.
    func testDecodeFiltersToPages() throws {
        let body = """
        [
          {"type":"page","id":"a","url":"https://a","title":"A","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/a"},
          {"type":"service_worker","id":"b","url":"https://b","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/b"},
          {"id":"c","url":"https://c","title":"C","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/c"}
        ]
        """
        let targets = try CDPTarget.decodeList(data(body))
        XCTAssertEqual(targets.map(\.id), ["a", "c"])
        // The defaulted-type entry reports "page" honestly.
        XCTAssertEqual(targets[1].type, "page")
        XCTAssertEqual(targets[0].title, "A")
    }

    /// Non-JSON input throws `cdpTransport` (a clean refuse), not a leaked
    /// decode error. Port of `test_list_targets_malformed_json_raises`.
    func testDecodeMalformedThrows() {
        XCTAssertThrowsError(try CDPTarget.decodeList(data("<html>not json</html>"))) { error in
            guard case GhostHandsError.cdpTransport = error else {
                return XCTFail("expected cdpTransport, got \(error)")
            }
        }
    }

    /// An empty array is honest empty `[]`, NOT a throw — no tabs is a real,
    /// reportable state.
    func testDecodeEmptyArrayIsHonestEmpty() throws {
        XCTAssertEqual(try CDPTarget.decodeList(data("[]")), [])
    }

    /// A top-level JSON OBJECT (not the required array) throws — the shape is
    /// wrong, refuse rather than coerce.
    func testDecodeNonArrayThrows() {
        XCTAssertThrowsError(try CDPTarget.decodeList(data("{\"foo\":1}"))) { error in
            guard case GhostHandsError.cdpTransport = error else {
                return XCTFail("expected cdpTransport, got \(error)")
            }
        }
    }

    /// A page-shaped entry that carries no `id` is malformed → throws (never a
    /// synthesised empty id).
    func testDecodePageWithoutIdThrows() {
        let body = "[{\"type\":\"page\",\"url\":\"https://x\"}]"
        XCTAssertThrowsError(try CDPTarget.decodeList(data(body))) { error in
            guard case GhostHandsError.cdpTransport = error else {
                return XCTFail("expected cdpTransport, got \(error)")
            }
        }
    }

    /// `/json/version` decodes its string-valued keys tolerantly.
    func testDecodeVersionPullsStrings() throws {
        let body = """
        {"Browser":"Chrome/120","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/x","Protocol-Version":1.3}
        """
        let v = try CDPTarget.decodeVersion(data(body))
        XCTAssertEqual(v["Browser"], "Chrome/120")
        XCTAssertEqual(v["webSocketDebuggerUrl"], "ws://127.0.0.1:9222/devtools/browser/x")
        // A non-string value is simply omitted (tolerant), not a throw.
        XCTAssertNil(v["Protocol-Version"])
    }

    /// THE security rail (pure): loopback hosts pass, everything else is refused.
    func testIsLoopbackGuard() {
        XCTAssertTrue(CDPTarget.isLoopback("ws://127.0.0.1:9222/devtools/page/X"))
        XCTAssertTrue(CDPTarget.isLoopback("ws://localhost:9222/devtools/page/X"))
        XCTAssertTrue(CDPTarget.isLoopback("ws://[::1]:9222/devtools/page/X"))

        XCTAssertFalse(CDPTarget.isLoopback("ws://10.0.0.5:9222/devtools/page/X"))
        XCTAssertFalse(CDPTarget.isLoopback("ws://evil.com/devtools/page/X"))
        XCTAssertFalse(CDPTarget.isLoopback("ws://192.168.1.10:9222/x"))
        // An unparseable / host-less URL is NOT loopback (refuse-on-unknown).
        XCTAssertFalse(CDPTarget.isLoopback("not a url"))
    }
}
