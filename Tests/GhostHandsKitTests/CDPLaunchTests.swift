import Foundation
import XCTest
@testable import GhostHandsKit

/// Hermetic — the two PURE cores of the consent-gated isolated relaunch (CDP
/// Slice 4), over FABRICATED inputs only. NEVER launches a browser, NEVER opens a
/// socket, NEVER touches the filesystem: every input is a hand-built sidecar
/// string / `Data` or a pair of booleans. Mirrors `InstallDecisionTests` /
/// `CDPTargetTests` (drive the pure `parse`/`decide` funcs, assert on the model or
/// the honest throw).
///
/// The IMPURE half — `CDPLauncher.launch` (Process spawn + sidecar file read) — is
/// DELIBERATELY untested here; it is exercised only in manual live-verify, per the
/// design doc. We only assert its PURE inputs: the launch-argument shape (which
/// encodes the security posture) is checked below.
final class CDPLaunchTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - DevToolsActivePort sidecar parser (PURE)

    /// The happy path: two lines → (port, wsPath). The canonical Chromium sidecar.
    func testParseTwoLineSidecar() throws {
        let parsed = try DevToolsActivePort.parse("51763\n/devtools/browser/ab12-cd34")
        XCTAssertEqual(parsed.port, 51763)
        XCTAssertEqual(parsed.wsPath, "/devtools/browser/ab12-cd34")
    }

    /// A trailing newline (the file usually ends with one) is tolerated — the
    /// trailing empty line is dropped, not treated as a bad ws path.
    func testParseTrailingNewline() throws {
        let parsed = try DevToolsActivePort.parse("9311\n/devtools/browser/xyz\n")
        XCTAssertEqual(parsed.port, 9311)
        XCTAssertEqual(parsed.wsPath, "/devtools/browser/xyz")
    }

    /// Whitespace around either line is trimmed (a port line with a stray CR/space
    /// still parses to the bare integer; the ws path is trimmed too).
    func testParseTrimsWhitespace() throws {
        let parsed = try DevToolsActivePort.parse("  42001  \n  /devtools/browser/p  ")
        XCTAssertEqual(parsed.port, 42001)
        XCTAssertEqual(parsed.wsPath, "/devtools/browser/p")
    }

    /// Only a port line (no ws path) is tolerated as an empty path — the PORT is
    /// what's mandatory; some builds write only the port.
    func testParsePortOnlyYieldsEmptyWsPath() throws {
        let parsed = try DevToolsActivePort.parse("60123")
        XCTAssertEqual(parsed.port, 60123)
        XCTAssertEqual(parsed.wsPath, "")
    }

    /// Bytes overload decodes UTF-8 then parses — same result as the String path.
    func testParseDataOverload() throws {
        let parsed = try DevToolsActivePort.parse(data("12345\n/devtools/browser/d"))
        XCTAssertEqual(parsed.port, 12345)
        XCTAssertEqual(parsed.wsPath, "/devtools/browser/d")
    }

    /// The high end of the valid range parses (boundary).
    func testParseMaxPort() throws {
        XCTAssertEqual(try DevToolsActivePort.parse("65535").port, 65535)
    }

    /// An EMPTY sidecar throws — never a guessed/defaulted port.
    func testParseEmptyThrows() {
        assertPortUnreadable(try DevToolsActivePort.parse(""))
    }

    /// A blank first line (only a newline) throws — no port to read.
    func testParseBlankFirstLineThrows() {
        assertPortUnreadable(try DevToolsActivePort.parse("\n/devtools/browser/x"))
    }

    /// A non-integer port line throws — `"9222junk"` must NOT coerce to 9222.
    func testParseNonIntegerPortThrows() {
        assertPortUnreadable(try DevToolsActivePort.parse("9222junk\n/devtools/browser/x"))
    }

    /// A textual port line throws (a captive-portal / log line written where a port
    /// was expected).
    func testParseTextPortThrows() {
        assertPortUnreadable(try DevToolsActivePort.parse("not-a-port\n/ws"))
    }

    /// Port 0 throws — `--remote-debugging-port=0` is what we PASS, but the OS must
    /// write back the REAL bound port; a literal 0 in the sidecar is malformed.
    func testParseZeroPortThrows() {
        assertPortUnreadable(try DevToolsActivePort.parse("0\n/devtools/browser/x"))
    }

    /// A negative port throws (boundary below the valid range).
    func testParseNegativePortThrows() {
        assertPortUnreadable(try DevToolsActivePort.parse("-1\n/ws"))
    }

    /// A port above 65535 throws (boundary above the valid range).
    func testParseOutOfRangePortThrows() {
        assertPortUnreadable(try DevToolsActivePort.parse("65536\n/ws"))
    }

    /// Non-UTF-8 bytes throw (the data overload refuses lossy decode rather than
    /// guessing).
    func testParseNonUTF8Throws() {
        // 0xFF 0xFE is not valid UTF-8.
        assertPortUnreadable(try DevToolsActivePort.parse(Data([0xFF, 0xFE, 0x00])))
    }

    /// The `Parsed` value is `Equatable` — same content compares equal, different
    /// port compares unequal (used downstream for honest reporting).
    func testParsedEquatable() throws {
        let a = try DevToolsActivePort.parse("3000\n/x")
        let b = try DevToolsActivePort.parse("3000\n/x")
        let c = try DevToolsActivePort.parse("3001\n/x")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Launch decision (PURE) — exhaustive truth table

    /// Port open, no relaunch → connect to the existing instance (the default).
    func testDecideOpenNoRelaunchConnects() {
        XCTAssertEqual(
            CDPLaunchDecision.decide(portOpen: true, relaunchRequested: false),
            .connectExisting)
    }

    /// Port open WITH relaunch → STILL connect existing. We never relaunch over a
    /// live port — an already-open instance is always honored.
    func testDecideOpenWithRelaunchStillConnects() {
        XCTAssertEqual(
            CDPLaunchDecision.decide(portOpen: true, relaunchRequested: true),
            .connectExisting)
    }

    /// Port closed, no relaunch → REFUSE. The unchanged default: relaunch is
    /// strictly opt-in, so a closed port without the flag still refuses.
    func testDecideClosedNoRelaunchRefuses() {
        XCTAssertEqual(
            CDPLaunchDecision.decide(portOpen: false, relaunchRequested: false),
            .refuseClosed)
    }

    /// Port closed WITH relaunch → launch an isolated instance. The ONLY path that
    /// relaunches, and only on explicit consent.
    func testDecideClosedWithRelaunchLaunches() {
        XCTAssertEqual(
            CDPLaunchDecision.decide(portOpen: false, relaunchRequested: true),
            .relaunchIsolated)
    }

    /// The full 2×2 truth table asserted in one place — the security contract is
    /// exactly these four outcomes, nothing else.
    func testDecideFullTruthTable() {
        let table: [(open: Bool, relaunch: Bool, expect: CDPLaunchDecision)] = [
            (true,  false, .connectExisting),
            (true,  true,  .connectExisting),
            (false, false, .refuseClosed),
            (false, true,  .relaunchIsolated),
        ]
        for row in table {
            XCTAssertEqual(
                CDPLaunchDecision.decide(portOpen: row.open, relaunchRequested: row.relaunch),
                row.expect,
                "open=\(row.open) relaunch=\(row.relaunch)")
        }
    }

    // MARK: - Launch arguments (PURE) — the security posture is auditable

    /// The launch args encode the security posture: ephemeral port (0, OS picks),
    /// an isolated `--user-data-dir` at the GIVEN temp path, and NO `--no-sandbox`
    /// (the Chrome sandbox stays on).
    func testLaunchArgumentsEncodeSecurityPosture() {
        let args = CDPLauncher.launchArguments(profileDir: "/tmp/ghosthands-cdp/profile-x")
        XCTAssertTrue(args.contains("--remote-debugging-port=0"),
                      "must pass ephemeral port 0 (OS picks), never a fixed 9222")
        XCTAssertTrue(args.contains("--user-data-dir=/tmp/ghosthands-cdp/profile-x"),
                      "must isolate to the given throwaway profile dir")
        XCTAssertFalse(args.contains("--no-sandbox"),
                       "the Chrome sandbox must stay ON (never disabled here)")
        // The throwaway-instance courtesy flags so it doesn't nag.
        XCTAssertTrue(args.contains("--no-first-run"))
        XCTAssertTrue(args.contains("--no-default-browser-check"))
    }

    /// The isolated profile dir is ALWAYS under the system temp dir and NEVER a
    /// real-profile path — asserted on the path the args would carry.
    func testLaunchArgumentsProfileIsUnderTempByConstruction() throws {
        // makeIsolatedProfileDir writes to disk, so we don't call it; instead we
        // assert the launch-args contract: whatever profile path is passed is the
        // one isolated. The impure dir-creation is covered in live-verify. Here we
        // confirm the arg simply mirrors the input (no hidden real-profile path).
        let temp = FileManager.default.temporaryDirectory.path
        let args = CDPLauncher.launchArguments(profileDir: temp + "/p")
        XCTAssertTrue(args.contains("--user-data-dir=\(temp)/p"))
        XCTAssertFalse(args.contains { $0.contains("Library/Application Support") },
                       "must never point at a real browser profile")
    }

    // MARK: - helper

    private func assertPortUnreadable(_ expr: @autoclosure () throws -> DevToolsActivePort.Parsed,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) { error in
            guard case GhostHandsError.devToolsPortUnreadable = error else {
                return XCTFail("expected devToolsPortUnreadable, got \(error)",
                               file: file, line: line)
            }
        }
    }
}
