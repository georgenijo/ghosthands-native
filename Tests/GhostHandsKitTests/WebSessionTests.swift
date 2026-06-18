import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE half of the managed session (issue #9): the verb-targeting
/// precedence, the persisted Codable shape, the URL-aware launch arguments, and
/// the refuse messages. The actual launch / kill / store IO is impure (mirrors
/// `CDPLauncher`) and exercised only in live-verify, never here.
final class WebSessionTests: XCTestCase {
    private func sampleSession(port: Int = 51763) -> WebSessionInfo {
        WebSessionInfo(port: port, pid: 4242, profileDir: "/tmp/ghosthands-cdp/profile-x",
                       browser: "Brave Browser", binaryPath: "/Applications/Brave Browser.app",
                       url: "https://example.com/")
    }

    // MARK: effectivePort — explicit flag ALWAYS wins, then session, then default

    func testEffectivePortExplicitWins() {
        // An explicit --debug-port overrides even a live session (the user asked).
        XCTAssertEqual(
            WebSession.effectivePort(explicit: 9999, session: sampleSession()), 9999)
    }

    func testEffectivePortFallsToSession() {
        XCTAssertEqual(
            WebSession.effectivePort(explicit: nil, session: sampleSession(port: 51763)), 51763)
    }

    func testEffectivePortFallsToDefaultWhenNoSession() {
        XCTAssertEqual(WebSession.effectivePort(explicit: nil, session: nil), 9222)
        XCTAssertEqual(WebSession.effectivePort(explicit: nil, session: nil), WebSession.defaultPort)
    }

    // MARK: effectiveBrowser — explicit positional wins, then session, then nil

    func testEffectiveBrowserExplicitWins() {
        XCTAssertEqual(
            WebSession.effectiveBrowser(explicit: "Chrome", session: sampleSession()), "Chrome")
    }

    func testEffectiveBrowserFallsToSession() {
        XCTAssertEqual(
            WebSession.effectiveBrowser(explicit: nil, session: sampleSession()), "Brave Browser")
    }

    func testEffectiveBrowserNilWhenNeither() {
        XCTAssertNil(WebSession.effectiveBrowser(explicit: nil, session: nil))
        // An empty explicit string is treated as absent (falls through to session).
        XCTAssertEqual(
            WebSession.effectiveBrowser(explicit: "", session: sampleSession()), "Brave Browser")
    }

    // MARK: persisted shape round-trips (survives across CLI processes)

    func testSessionInfoCodableRoundTrip() throws {
        let info = sampleSession()
        let data = try JSONEncoder().encode(info)
        let back = try JSONDecoder().decode(WebSessionInfo.self, from: data)
        XCTAssertEqual(info, back)
    }

    // MARK: URL-aware launch arguments — same security posture, url appended last

    func testLaunchArgsAppendURLPositional() {
        let args = CDPLauncher.launchArguments(
            profileDir: "/tmp/ghosthands-cdp/profile-x", url: "https://example.com/")
        XCTAssertEqual(args.last, "https://example.com/")          // url is the positional
        XCTAssertTrue(args.contains("--remote-debugging-port=0"))  // OS picks the port
        XCTAssertTrue(args.contains("--user-data-dir=/tmp/ghosthands-cdp/profile-x"))
        XCTAssertFalse(args.contains("--no-sandbox"))              // sandbox stays ON
    }

    func testLaunchArgsOmitEmptyURL() {
        let none = CDPLauncher.launchArguments(profileDir: "/tmp/p", url: nil)
        XCTAssertFalse(none.contains { $0.hasPrefix("http") })
        // The no-url overload matches the url:nil form exactly (back-compat).
        XCTAssertEqual(CDPLauncher.launchArguments(profileDir: "/tmp/p"), none)
    }

    // MARK: refuse messages are honest

    func testSessionRefusesAreHonest() {
        let already = GhostHandsError.sessionAlreadyOpen(port: 51763, pid: 4242).description
        XCTAssertTrue(already.contains("51763"))
        XCTAssertTrue(already.lowercased().contains("web close"))

        let none = GhostHandsError.noSession.description
        XCTAssertTrue(none.lowercased().contains("no managed web session"))
        XCTAssertTrue(none.lowercased().contains("web open"))
    }
}
