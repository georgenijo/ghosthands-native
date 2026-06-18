import Foundation
import XCTest
@testable import GhostHandsKit

/// Hermetic — drives ONLY the PURE shaper half of the opt-in failure-artifacts
/// feature on FABRICATED inputs. It NEVER writes a real file, NEVER captures a
/// real screenshot, and NEVER touches the environment: every input is a
/// hand-built `FailureArtifact.Entry` or a literal env dictionary. The impure
/// half (`record` — real screen capture + JSONL append) is deliberately NOT
/// exercised here, mirroring InstallDecisionTests / ShotDecisionTests (drive the
/// pure func, assert the shaped string / decision).
final class FailureArtifactTests: XCTestCase {

    // MARK: helpers

    private func entry(
        timestamp: String = "2026-06-18T12:00:00Z",
        verb: String = "click",
        argv: [String] = ["ghosthands", "click", "Save", "TextEdit"],
        error: String = "no element named \"Save\" on screen in TextEdit",
        exitCode: Int32 = 1,
        screenshot: String? = nil
    ) -> FailureArtifact.Entry {
        FailureArtifact.Entry(
            timestamp: timestamp, verb: verb, argv: argv,
            errorMessage: error, exitCode: exitCode, screenshotPath: screenshot)
    }

    /// Parse the shaped line back through Foundation's JSON to PROVE it is valid
    /// JSON with the expected shape (a strong oracle: if escaping is wrong, this
    /// throws / mismatches).
    private func parsed(_ line: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(obj as? [String: Any])
    }

    // MARK: 1. stable key set + order

    func testStableKeySetAndOrder() {
        let line = FailureArtifact.logLine(entry(screenshot: "/tmp/a.png"))
        // The exact key ORDER is part of the contract (a human reads the log).
        let keysInOrder = ["timestamp", "verb", "argv", "error", "exitCode", "screenshot"]
        var cursor = line.startIndex
        for key in keysInOrder {
            let needle = "\"\(key)\":"
            guard let r = line.range(of: needle, range: cursor ..< line.endIndex) else {
                return XCTFail("missing key \(key) (in order) in \(line)")
            }
            cursor = r.upperBound
        }
        // Exactly those six keys — no extras, none missing.
        let obj = try? parsed(line)
        XCTAssertEqual(Set(obj?.keys ?? [:].keys), Set(keysInOrder))
    }

    // MARK: 2. with screenshot ⇒ JSON string; without ⇒ JSON null (always present)

    func testScreenshotPresentIsAQuotedString() throws {
        let line = FailureArtifact.logLine(entry(screenshot: "/tmp/shot.png"))
        XCTAssertTrue(line.contains("\"screenshot\":\"/tmp/shot.png\""))
        let obj = try parsed(line)
        XCTAssertEqual(obj["screenshot"] as? String, "/tmp/shot.png")
    }

    func testScreenshotAbsentIsLiteralNullNotOmitted() throws {
        let line = FailureArtifact.logLine(entry(screenshot: nil))
        // Literal `null` token — NOT the string "null", NOT omitted.
        XCTAssertTrue(line.contains("\"screenshot\":null"))
        XCTAssertFalse(line.contains("\"screenshot\":\"null\""))
        let obj = try parsed(line)
        XCTAssertTrue(obj["screenshot"] is NSNull)
    }

    // MARK: 3. fields round-trip with the right types/values

    func testFieldsRoundTrip() throws {
        let line = FailureArtifact.logLine(entry(
            timestamp: "2026-06-18T09:30:15Z",
            verb: "web read",
            argv: ["ghosthands", "web", "read", "Brave"],
            error: "no DevTools port",
            exitCode: 2,
            screenshot: "/art/x.png"))
        let obj = try parsed(line)
        XCTAssertEqual(obj["timestamp"] as? String, "2026-06-18T09:30:15Z")
        XCTAssertEqual(obj["verb"] as? String, "web read")
        XCTAssertEqual(obj["argv"] as? [String], ["ghosthands", "web", "read", "Brave"])
        XCTAssertEqual(obj["error"] as? String, "no DevTools port")
        XCTAssertEqual(obj["exitCode"] as? Int, 2)
        XCTAssertEqual(obj["screenshot"] as? String, "/art/x.png")
    }

    // MARK: 4. special characters are escaped (the JSONL-framing guarantee)

    func testSpecialCharsInErrorAreEscaped() throws {
        // An error message with a quote, a backslash, a newline and a tab — these
        // would shatter the JSONL line if not escaped.
        let nasty = "bad \"name\" with \\ and\nnewline\tand tab"
        let line = FailureArtifact.logLine(entry(error: nasty))
        // The shaped line itself must be SINGLE-line (no raw newline mid-record).
        XCTAssertFalse(line.contains("\n"), "raw newline leaked into the JSON line")
        // And it must parse back to the ORIGINAL string exactly.
        let obj = try parsed(line)
        XCTAssertEqual(obj["error"] as? String, nasty)
    }

    func testSpecialCharsInArgvAndVerbAreEscaped() throws {
        let line = FailureArtifact.logLine(entry(
            verb: "ty\"pe",
            argv: ["ghosthands", "type", "he said \"hi\"\n", "Field\\X", "App"]))
        let obj = try parsed(line)
        XCTAssertEqual(obj["verb"] as? String, "ty\"pe")
        XCTAssertEqual(
            obj["argv"] as? [String],
            ["ghosthands", "type", "he said \"hi\"\n", "Field\\X", "App"])
    }

    func testControlCharBelow0x20IsUnicodeEscaped() throws {
        // A raw NUL / bell etc. must become \u00XX, never a literal byte.
        let withCtrl = "x\u{01}y\u{1F}z"
        let line = FailureArtifact.logLine(entry(error: withCtrl))
        XCTAssertTrue(line.contains("\\u0001"))
        XCTAssertTrue(line.contains("\\u001f"))
        let obj = try parsed(line)
        XCTAssertEqual(obj["error"] as? String, withCtrl)
    }

    // MARK: 5. empty argv + empty strings stay valid JSON

    func testEmptyArgvAndEmptyStrings() throws {
        let line = FailureArtifact.logLine(entry(verb: "", argv: [], error: ""))
        XCTAssertTrue(line.contains("\"argv\":[]"))
        let obj = try parsed(line)
        XCTAssertEqual(obj["argv"] as? [String], [])
        XCTAssertEqual(obj["verb"] as? String, "")
        XCTAssertEqual(obj["error"] as? String, "")
    }

    // MARK: 6. exit code is an unquoted JSON number (not a string)

    func testExitCodeIsANumber() throws {
        let line = FailureArtifact.logLine(entry(exitCode: 2))
        XCTAssertTrue(line.contains("\"exitCode\":2"))
        XCTAssertFalse(line.contains("\"exitCode\":\"2\""))
        let obj = try parsed(line)
        XCTAssertEqual(obj["exitCode"] as? Int, 2)
    }

    // MARK: 7. screenshot file name is path-safe (verb spaces + ISO colons)

    func testScreenshotFileNameSanitizesColonsAndSpaces() {
        let name = FailureArtifact.screenshotFileName(
            timestamp: "2026-06-18T12:00:00Z", verb: "web read")
        XCTAssertFalse(name.contains(":"), "colon would be hostile on some filesystems")
        XCTAssertFalse(name.contains(" "), "space leaked into filename")
        XCTAssertTrue(name.hasSuffix(".png"))
        // The verb's space became a separator-safe char, both halves preserved.
        XCTAssertTrue(name.contains("web_read"))
    }

    func testLogFileNameIsFixed() {
        XCTAssertEqual(FailureArtifact.logFileName, "ghosthands-failures.jsonl")
    }

    // MARK: 8. the env gate predicate (the OFF-by-default guarantee, pure half)

    func testEnabledIsFalseWhenUnset() {
        XCTAssertFalse(FailureArtifact.enabled(in: [:]))
    }

    func testEnabledIsFalseWhenEmpty() {
        XCTAssertFalse(FailureArtifact.enabled(in: ["GHOSTHANDS_ARTIFACTS": ""]))
    }

    func testEnabledIsTrueWhenSetToADir() {
        XCTAssertTrue(FailureArtifact.enabled(in: ["GHOSTHANDS_ARTIFACTS": "/tmp/art"]))
    }

    func testEnvVarNameIsStable() {
        XCTAssertEqual(FailureArtifact.envVar, "GHOSTHANDS_ARTIFACTS")
    }

    // MARK: 9. iso8601 is parseable + stable shape

    func testIso8601RoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)  // a fixed instant
        let s = FailureArtifact.iso8601(date)
        let back = try XCTUnwrap(ISO8601DateFormatter().date(from: s),
                                 "iso8601 output should re-parse: \(s)")
        // Same instant (to the second — the formatter's resolution).
        XCTAssertEqual(back.timeIntervalSince1970, 1_750_000_000, accuracy: 1.0)
    }
}
