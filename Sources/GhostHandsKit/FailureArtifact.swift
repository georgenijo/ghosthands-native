import AppKit
import CoreGraphics
import Foundation

/// Opt-in FAILURE ARTIFACTS — a pure side-channel forensics layer.
///
/// When a verb REFUSES (the centralized `fail*` path in the CLI), and ONLY when
/// the user has opted in via `GHOSTHANDS_ARTIFACTS=<dir>`, we best-effort:
///   1. capture a full-screen PNG of the screen at the moment of the refuse, and
///   2. append one structured JSON line to `<dir>/ghosthands-failures.jsonl`
/// so an agent or CI can see WHAT the screen looked like when the verb refused.
///
/// HONESTY / safety contract (the whole reason this is its own audited file):
///   - OFF by default. With the env var unset/empty, behavior is byte-for-byte
///     unchanged — no capture, no log, identical exit codes.
///   - It NEVER changes a verb's outcome or exit code. The capture + file IO are
///     best-effort and fully swallowed; a capture/log failure logs `null` for the
///     screenshot (or skips silently) and NEVER turns into a new error.
///   - The PURE half (`logLine`) shapes a failure entry into a JSON string and is
///     unit-tested over fabricated inputs. The IMPURE half (`record`, the screen
///     capture, the file append) is the side-effecting orchestrator — not unit
///     tested (it touches the real screen / disk).
public enum FailureArtifact {

    // MARK: - PURE shaper (unit-tested)

    /// The structured fields of one failure-log entry. Pure value type; carries
    /// no IO. `screenshotPath` is nil when capture failed / was unavailable.
    public struct Entry: Sendable, Equatable {
        public let timestamp: String   // ISO8601 (caller supplies, via Date())
        public let verb: String
        public let argv: [String]
        public let errorMessage: String
        public let exitCode: Int32
        public let screenshotPath: String?

        public init(timestamp: String, verb: String, argv: [String],
                    errorMessage: String, exitCode: Int32, screenshotPath: String?) {
            self.timestamp = timestamp
            self.verb = verb
            self.argv = argv
            self.errorMessage = errorMessage
            self.exitCode = exitCode
            self.screenshotPath = screenshotPath
        }
    }

    /// Shape a failure entry into ONE compact JSON line (no trailing newline).
    ///
    /// PURE & DETERMINISTIC — a function of its inputs only, so it is the unit-
    /// tested core. Guarantees:
    ///   - a STABLE key set in a STABLE order:
    ///     timestamp, verb, argv, error, exitCode, screenshot
    ///   - `screenshot` is ALWAYS present — a JSON string when captured, JSON
    ///     `null` when not (never omitted, so a consumer can tell "no screenshot"
    ///     apart from a malformed line).
    ///   - every string value is JSON-escaped (quotes, backslashes, control chars,
    ///     newlines/tabs) so a wild error message or an argv with quotes can never
    ///     break the JSONL framing.
    public static func logLine(_ e: Entry) -> String {
        var s = "{"
        s += jsonKey("timestamp") + jsonString(e.timestamp) + ","
        s += jsonKey("verb") + jsonString(e.verb) + ","
        s += jsonKey("argv") + jsonArray(e.argv) + ","
        s += jsonKey("error") + jsonString(e.errorMessage) + ","
        s += jsonKey("exitCode") + String(e.exitCode) + ","
        s += jsonKey("screenshot") + (e.screenshotPath.map(jsonString) ?? "null")
        s += "}"
        return s
    }

    // MARK: pure JSON encoding helpers (hand-rolled so the key ORDER is fixed —
    // JSONEncoder sorts or randomizes keys, which we don't want for a forensic
    // log a human reads line-by-line)

    private static func jsonKey(_ k: String) -> String { jsonString(k) + ":" }

    private static func jsonArray(_ items: [String]) -> String {
        "[" + items.map(jsonString).joined(separator: ",") + "]"
    }

    /// Encode `value` as a JSON string literal, escaping per RFC 8259. We escape
    /// the two structural chars (`"` and `\`), the named short escapes, and ALL
    /// other control chars (< 0x20) as `\u00XX`, so no byte can break the line.
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: pure filename + dir helpers (pure string logic, unit-testable)

    /// The fixed JSONL log file name appended inside the artifacts dir.
    public static let logFileName = "ghosthands-failures.jsonl"

    /// The per-failure screenshot file name: `<timestamp>-<verb>.png`, with any
    /// filesystem-hostile characters in the timestamp/verb (`:` `/` spaces) made
    /// path-safe, so a verb like "web read" or an ISO timestamp with colons can't
    /// produce an unopenable path. Pure — no IO.
    public static func screenshotFileName(timestamp: String, verb: String) -> String {
        "\(sanitize(timestamp))-\(sanitize(verb)).png"
    }

    private static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        return out
    }

    // MARK: - ISO8601 timestamp (a thin, deterministic-format wrapper over Date)

    /// Format an instant as an ISO8601 string (the timestamp written to the log
    /// and embedded in the screenshot filename). A pure function of the Date so a
    /// test can pin it; the impure path passes `Date()`.
    public static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - IMPURE recorder (NOT unit-tested — touches real screen + disk)

    /// The opt-in environment variable. When set to a non-empty directory path,
    /// failure artifacts are captured there; unset/empty ⇒ the feature is OFF and
    /// `record` is a no-op.
    public static let envVar = "GHOSTHANDS_ARTIFACTS"

    /// Whether the feature is enabled for this `environment` (the env var names a
    /// non-empty dir). Pure predicate — lets the SYNCHRONOUS fail path skip ALL
    /// artifact work (incl. the main-thread CGS bootstrap) when disabled, so the
    /// disabled path is byte-for-byte unchanged.
    public static func enabled(in environment: [String: String]) -> Bool {
        if let dir = environment[envVar], !dir.isEmpty { return true }
        return false
    }

    /// SYNCHRONOUS, fully-swallowed bridge for the centralized `fail*` path (which
    /// is `-> Never` and runs on the main thread just before `exit`). It:
    ///   1. returns AT ONCE when disabled (the unchanged-when-off guarantee),
    ///   2. bootstraps the CGS (WindowServer) connection on the MAIN thread once
    ///      (`NSApplication.shared` — a background accessory; no focus steal, no
    ///      Dock icon, same as `shot`), THEN
    ///   3. runs the async `record` on a DETACHED background task and BLOCKS the
    ///      main thread on a semaphore until it finishes.
    /// Because the detached task needs no main-actor hop (the capture is off-main
    /// and the bootstrap already ran), blocking the main thread cannot deadlock.
    /// NEVER throws; NEVER alters the exit code.
    public static func recordBlocking(
        verb: String,
        argv: [String],
        errorMessage: String,
        exitCode: Int32,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) {
        guard enabled(in: environment) else { return }

        // CGS bootstrap on the main thread — see Shot.shot. Establishing the
        // shared NSApplication here means the off-main capture can use the CGS /
        // SCK APIs without aborting, and without needing a main-actor hop while
        // we block the main thread below.
        if Thread.isMainThread {
            _ = NSApplication.shared
        }

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await record(verb: verb, argv: argv, errorMessage: errorMessage,
                         exitCode: exitCode, environment: environment, now: now)
            sem.signal()
        }
        sem.wait()
    }

    /// Record a failure artifact for a refuse. Best-effort and TOTALLY swallowed:
    /// this function can NEVER throw and NEVER affects the caller's exit code —
    /// it returns Void and any internal failure (no permission, capture error,
    /// unwritable dir) is silently degraded (screenshot ⇒ null, or the whole
    /// record skipped). Prefer `recordBlocking` from the synchronous fail path;
    /// this async form is the testable/awaitable core.
    ///
    /// `argv` is the FULL process argv (CommandLine.arguments) so the log captures
    /// exactly how the tool was invoked, with no per-verb plumbing. `environment`
    /// and `now` are injected (defaulting to the live process env / `Date()`) so
    /// the env-gating is exercised, but the capture + file IO remain live.
    public static func record(
        verb: String,
        argv: [String],
        errorMessage: String,
        exitCode: Int32,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async {
        // Gate FIRST — OFF unless the env var names a non-empty dir. This is the
        // byte-for-byte-unchanged guarantee when disabled.
        guard let dir = environment[envVar], !dir.isEmpty else { return }

        let timestamp = iso8601(now)
        let dirURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath,
                         isDirectory: true)

        // Ensure the dir exists (best-effort; a failure just means we likely
        // can't write the log either, and we'll degrade gracefully below).
        try? FileManager.default.createDirectory(
            at: dirURL, withIntermediateDirectories: true)

        // Best-effort screenshot. ANY failure ⇒ nil ⇒ logged as `null`. Wrapped
        // so even an unexpected throw out of the capture can't escape.
        var screenshotPath: String? = nil
        let shotURL = dirURL.appendingPathComponent(
            screenshotFileName(timestamp: timestamp, verb: verb))
        screenshotPath = await Shot.captureMainDisplayPNG(to: shotURL)

        let entry = Entry(timestamp: timestamp, verb: verb, argv: argv,
                          errorMessage: errorMessage, exitCode: exitCode,
                          screenshotPath: screenshotPath)
        let line = logLine(entry) + "\n"

        // Append the JSON line. Best-effort: open-for-append, else create. A
        // write failure is swallowed — the refuse still exits with its real code.
        appendSwallowing(line, to: dirURL.appendingPathComponent(logFileName))
    }

    /// Append `text` to `url`, swallowing every error. Uses an append-mode file
    /// handle when the file exists, else writes it fresh. NEVER throws.
    private static func appendSwallowing(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // swallow
            }
        } else {
            // File doesn't exist yet (or couldn't be opened for append) — create.
            try? data.write(to: url, options: .atomic)
        }
    }
}
