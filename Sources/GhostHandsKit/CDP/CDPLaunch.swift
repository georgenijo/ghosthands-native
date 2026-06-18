import Foundation

// CDP Slice 4 — consent-gated, ISOLATED relaunch.
//
// By default every `web --cdp` verb connects ONLY to an ALREADY-open debug port;
// a closed port REFUSES (`cdpPortClosed`). This file adds the OPT-IN escape hatch:
// when (and ONLY when) the explicit `--relaunch` flag is given AND the port is
// closed, launch a SEPARATE, throwaway browser instance for automation — never
// the user's real profile, never silently.
//
// SECURITY posture (mined from agent-browser, see docs/CDP-PLAN.md §"Mined"):
//   - ephemeral `--remote-debugging-port=0` — the OS picks a free port; we do NOT
//     guess 9222. The chosen port is read back from the browser's sidecar file.
//   - isolated throwaway `--user-data-dir` under the SYSTEM temp dir — the user's
//     real profile / cookies / history are untouched.
//   - loopback-only stays enforced downstream: every ws connect still passes
//     `CDPTarget.isLoopback` (see `CDPSession.open`), so this path never widens
//     the network surface.
//
// SPLIT: the two decisions below are PURE and hermetically unit-tested over
// fabricated inputs (sidecar parse + launch decision). The actual `Process`
// launch + sidecar file read (`CDPLauncher`) is the IMPURE half — it touches the
// filesystem and spawns a child, so it is exercised only in manual live-verify,
// never in a test.

// MARK: - PURE: DevToolsActivePort sidecar parser

/// The PURE parser for the `DevToolsActivePort` sidecar Chromium writes into the
/// `--user-data-dir` after binding its debug port. The file is exactly two lines:
///
///     <port>\n<ws-path>
///
/// e.g.
///
///     51763
///     /devtools/browser/ab12-cd34-…
///
/// We NEVER guess a port — a malformed sidecar (empty, no port line, a non-integer
/// port, a non-positive port) parses to a throw, so the caller refuses rather than
/// connect to a fabricated port. The second line (the browser-level ws path) is
/// returned verbatim; an absent second line is tolerated as an empty path (some
/// builds write only the port), but a missing/garbage PORT is never tolerated.
///
/// Mirrors `Install.mountPoint(fromAttachPlist:)`: bytes in, model out, refuse on
/// malformed — so it is unit-tested on fabricated content with no real browser.
public enum DevToolsActivePort {
    /// The parsed sidecar: the OS-chosen debug port + the browser-level ws path.
    public struct Parsed: Sendable, Equatable {
        /// The port the browser actually bound (line 1). Always > 0.
        public let port: Int
        /// The browser-level WebSocket debugger path (line 2), e.g.
        /// `/devtools/browser/<uuid>`. Empty when the sidecar omits it.
        public let wsPath: String
        public init(port: Int, wsPath: String) {
            self.port = port
            self.wsPath = wsPath
        }
    }

    /// Parse the sidecar TEXT. Throws `devToolsPortUnreadable` on any malformed
    /// content (no port, a non-integer port, a non-positive port) — NEVER a
    /// guessed/defaulted port. The first line is the port; the rest (joined) is the
    /// ws path, trimmed of surrounding whitespace.
    public static func parse(_ text: String) throws -> Parsed {
        // Split on newlines and drop a trailing empty line from a final `\n`.
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = rawLines.first else {
            throw GhostHandsError.devToolsPortUnreadable(
                reason: "DevToolsActivePort is empty (no port line)")
        }
        let portLine = first.trimmingCharacters(in: .whitespaces)
        guard !portLine.isEmpty else {
            throw GhostHandsError.devToolsPortUnreadable(
                reason: "DevToolsActivePort first line is blank (no port)")
        }
        // A real port is a bare positive integer; anything else is refused, never
        // coerced (`Int("9222junk")` is nil → refuse; "0" / negatives → refuse).
        guard let port = Int(portLine) else {
            throw GhostHandsError.devToolsPortUnreadable(
                reason: "DevToolsActivePort port line is not an integer: "
                    + portLine.debugDescription)
        }
        guard port > 0, port <= 65535 else {
            throw GhostHandsError.devToolsPortUnreadable(
                reason: "DevToolsActivePort port \(port) is out of range (1…65535)")
        }
        // The ws path is the SECOND line (verbatim, trimmed). Tolerate its absence
        // as an empty path — but the port above is mandatory.
        let wsPath: String = rawLines.count >= 2
            ? rawLines[1].trimmingCharacters(in: .whitespaces)
            : ""
        return Parsed(port: port, wsPath: wsPath)
    }

    /// Parse sidecar BYTES (as written to disk). Refuses non-UTF-8 content
    /// (`devToolsPortUnreadable`) rather than decoding lossily.
    public static func parse(_ data: Data) throws -> Parsed {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GhostHandsError.devToolsPortUnreadable(
                reason: "DevToolsActivePort is not UTF-8")
        }
        return try parse(text)
    }
}

// MARK: - PURE: launch decision

/// The PURE three-way launch decision for a `web --cdp` verb, driven by two real
/// booleans (is the port open? did the user pass `--relaunch`?). Keeping it pure
/// means the security-critical "never relaunch silently" rule is unit-tested
/// exhaustively over the truth table, with no Process and no socket.
public enum CDPLaunchDecision: Sendable, Equatable {
    /// The debug port is already open → connect to the existing instance (the
    /// default, unchanged behavior). `relaunchRequested` is irrelevant here: an
    /// already-open port is always honored, we never relaunch over a live one.
    case connectExisting
    /// The port is closed and `--relaunch` was NOT given → REFUSE (`cdpPortClosed`).
    /// This is the unchanged default refuse — relaunch is strictly opt-in.
    case refuseClosed
    /// The port is closed AND `--relaunch` was given → launch a NEW, ISOLATED
    /// throwaway instance (ephemeral port + temp profile) for automation.
    case relaunchIsolated

    /// Decide PURELY from the two facts. The whole security contract in one place:
    ///
    ///   portOpen                       → connectExisting   (never relaunch over a live port)
    ///   !portOpen && !relaunchRequested → refuseClosed      (unchanged default refuse)
    ///   !portOpen &&  relaunchRequested → relaunchIsolated  (opt-in, isolated)
    public static func decide(portOpen: Bool, relaunchRequested: Bool) -> CDPLaunchDecision {
        if portOpen { return .connectExisting }
        return relaunchRequested ? .relaunchIsolated : .refuseClosed
    }
}

// MARK: - IMPURE: the actual isolated relaunch (NOT unit-tested)

/// What an isolated relaunch produced — reported to the human so the launch is
/// never silent: the binary that was spawned, the throwaway profile path, and the
/// OS-chosen port read back from the sidecar.
public struct CDPLaunchedInstance: Sendable, Equatable {
    /// The browser executable that was launched.
    public let binaryPath: String
    /// The throwaway `--user-data-dir` (under the system temp dir). NOT the user's
    /// real profile — disposable, no cookies/history.
    public let profileDir: String
    /// The debug port the OS picked (read from the sidecar, never guessed).
    public let port: Int
    /// The process id of the launched instance.
    public let pid: Int32
    public init(binaryPath: String, profileDir: String, port: Int, pid: Int32) {
        self.binaryPath = binaryPath
        self.profileDir = profileDir
        self.port = port
        self.pid = pid
    }
}

/// The IMPURE relaunch: spawn an isolated browser, then read the OS-chosen port
/// from the sidecar. NOT unit-tested — it spawns a child process and touches the
/// filesystem. Exercised only in manual live-verify, per the design doc. The two
/// security-critical DECISIONS it depends on (parse, decide) are pure and tested.
public enum CDPLauncher {
    /// How long to wait for the browser to write its `DevToolsActivePort` sidecar
    /// before refusing. Bounded — we NEVER spin forever waiting on a child that may
    /// never come up.
    static let sidecarDeadline: TimeInterval = 10
    /// Poll cadence while waiting for the sidecar to appear.
    static let pollInterval: TimeInterval = 0.1

    /// Create a FRESH throwaway profile directory under the SYSTEM temp dir. NEVER
    /// the user's real profile — a unique per-launch path so concurrent relaunches
    /// don't collide. Throws `relaunchFailed` if the temp dir can't be created.
    static func makeIsolatedProfileDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthands-cdp", isDirectory: true)
            .appendingPathComponent("profile-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: base, withIntermediateDirectories: true)
        } catch {
            throw GhostHandsError.relaunchFailed(
                reason: "could not create an isolated profile dir: "
                    + error.localizedDescription)
        }
        return base
    }

    /// The launch arguments for an isolated, ephemeral-port automation instance.
    /// PURE given a profile dir — so the exact security flags are visible and
    /// auditable. `--remote-debugging-port=0` lets the OS pick (read back from the
    /// sidecar); `--user-data-dir=<temp>` isolates the profile; `--no-first-run` /
    /// `--no-default-browser-check` keep the throwaway instance from nagging.
    ///
    /// NOTE: we DELIBERATELY do NOT pass `--no-sandbox` — the Chrome sandbox stays
    /// on (the agent-browser rule: only drop it under root/container detection,
    /// which we never do here).
    public static func launchArguments(profileDir: String) -> [String] {
        launchArguments(profileDir: profileDir, url: nil)
    }

    /// The launch arguments WITH an optional initial URL (issue #9's `web open
    /// <url>`). The URL is appended as a POSITIONAL arg — Chromium opens it as the
    /// first tab — so the managed session lands on the page directly. Same security
    /// posture as the no-URL form (ephemeral port, isolated temp profile, sandbox
    /// left ON). A nil/empty URL omits the positional (a blank new-tab instance).
    public static func launchArguments(profileDir: String, url: String?) -> [String] {
        var args = [
            "--remote-debugging-port=0",
            "--user-data-dir=\(profileDir)",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        if let url, !url.isEmpty { args.append(url) }
        return args
    }

    /// Launch `binaryPath` as an isolated automation instance and return the
    /// chosen port (read from the sidecar). Throws:
    ///   - `relaunchFailed`        — the binary could not be spawned, or the temp
    ///                               profile could not be created.
    ///   - `devToolsPortUnreadable` — the sidecar never appeared within the deadline,
    ///                                or its content was malformed.
    ///
    /// SECURITY: the port is ALWAYS read from the sidecar Chromium writes into the
    /// isolated profile — never guessed, never defaulted to 9222.
    static func launch(binaryPath: String, url: String? = nil) async throws -> CDPLaunchedInstance {
        let profileURL = try makeIsolatedProfileDir()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = launchArguments(profileDir: profileURL.path, url: url)
        // Silence the child's chatter; we read state from the sidecar, not stdio.
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw GhostHandsError.relaunchFailed(
                reason: "could not launch \(binaryPath): \(error.localizedDescription)")
        }

        let sidecar = profileURL.appendingPathComponent("DevToolsActivePort")
        let parsed = try await waitForSidecar(at: sidecar)
        return CDPLaunchedInstance(
            binaryPath: binaryPath, profileDir: profileURL.path,
            port: parsed.port, pid: process.processIdentifier)
    }

    /// Poll for the `DevToolsActivePort` sidecar until it appears AND parses, OR
    /// the deadline elapses. BOUNDED — a child that never writes the file raises
    /// `devToolsPortUnreadable` instead of spinning forever. The PURE
    /// `DevToolsActivePort.parse` does the actual decode (and may itself throw on
    /// malformed content, which we surface unchanged).
    static func waitForSidecar(at url: URL) async throws -> DevToolsActivePort.Parsed {
        let deadline = Date().addingTimeInterval(sidecarDeadline)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url) {
                // The file may exist but be momentarily empty (the browser is mid
                // write). A parse failure on a PRESENT file that is simply not
                // ready yet should retry until the deadline, not refuse instantly —
                // so we only surface a parse error once the deadline is hit.
                if let parsed = try? DevToolsActivePort.parse(data) {
                    return parsed
                }
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        // One last attempt so the FINAL failure carries the real parse reason (a
        // malformed-but-present sidecar) rather than a generic timeout.
        if let data = try? Data(contentsOf: url) {
            return try DevToolsActivePort.parse(data)
        }
        throw GhostHandsError.devToolsPortUnreadable(
            reason: "browser did not write a DevToolsActivePort sidecar within "
                + "\(Int(sidecarDeadline))s at \(url.path)")
    }
}
