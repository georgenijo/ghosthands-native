import AppKit
import AXorcist
import Foundation

// GhostHands WEB SESSION tier — a managed throwaway browser lifecycle (issue #9).
//
// Driving the CDP path used to require manual ceremony: `open -na … --args
// --remote-debugging-port … --user-data-dir=/tmp/…`, then `curl --retry` to poll
// for ready, then `kill`/`rm -rf` to tear down. `web open` collapses that to ONE
// command: spawn an ISOLATED throwaway instance (fresh temp profile, never the
// user's real one), let the OS pick a free port, WAIT until a debuggable page is
// listed, then persist a session handle so subsequent `web read/click/fill` in
// SEPARATE CLI processes auto-target it — no `--debug-port` needed. `web close`
// terminates the instance (plain SIGTERM, never -9) and removes the temp profile.
//
// HONESTY / SAFETY (unchanged contract):
//   - The throwaway profile is under the system temp dir; the user's real
//     profile / cookies / history are NEVER touched (same posture as --relaunch).
//   - `web open` returns ONLY once a driveable page target is listed — the
//     readiness is OBSERVED, never assumed.
//   - One active session at a time: opening over a LIVE session REFUSES (avoid
//     orphan processes); a stale session file (dead pid) is overwritten.
//
// PURITY: the persisted shape (`WebSessionInfo`, Codable) and the verb-resolution
// rules (`WebSession.effectivePort` / `effectiveBrowser`) are PURE and
// hermetically tested. The store IO + the actual launch/kill (mirroring
// `CDPLauncher`) are the impure half, exercised only in live-verify.

// MARK: - PURE: the persisted session shape

/// The managed session `web open` writes and `web close` consumes. Codable so it
/// survives across separate CLI processes (the whole point — the launching
/// process exits, but the throwaway browser and this handle persist).
public struct WebSessionInfo: Codable, Sendable, Equatable {
    /// The OS-chosen debug port (read from the sidecar, never guessed).
    public let port: Int
    /// The launched instance's pid — what `web close` terminates.
    public let pid: Int32
    /// The throwaway `--user-data-dir` (under the system temp dir) — removed on close.
    public let profileDir: String
    /// The resolved browser app name, e.g. "Brave Browser".
    public let browser: String
    /// The executable that was launched.
    public let binaryPath: String
    /// The initial URL opened.
    public let url: String

    public init(port: Int, pid: Int32, profileDir: String, browser: String,
                binaryPath: String, url: String) {
        self.port = port
        self.pid = pid
        self.profileDir = profileDir
        self.browser = browser
        self.binaryPath = binaryPath
        self.url = url
    }
}

// MARK: - PURE: verb-targeting resolution

/// The PURE rules that let subsequent `web` verbs auto-target a managed session.
/// Kept out of the IO so the precedence (explicit flag always wins) is unit-tested.
public enum WebSession {
    public static let defaultPort = 9222

    /// The debug port a verb should use: an EXPLICIT `--debug-port` ALWAYS wins
    /// (the user asked for a specific surface); else a live managed session's port;
    /// else the historical default 9222. So a session is a convenience, never an
    /// override of an explicit request.
    public static func effectivePort(explicit: Int?, session: WebSessionInfo?,
                                     default def: Int = defaultPort) -> Int {
        explicit ?? session?.port ?? def
    }

    /// The browser a verb should target: an EXPLICIT positional arg wins; else the
    /// managed session's browser; else nil (the caller then refuses on usage). This
    /// is what lets `web read` (no args) work right after `web open`.
    public static func effectiveBrowser(explicit: String?,
                                        session: WebSessionInfo?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        return session?.browser
    }
}

// MARK: - IMPURE: the session store (NOT unit-tested — filesystem IO)

/// Persists the single active session under `~/.ghosthands/web-session.json`.
/// Mirrors `CDPLauncher`: the IO is not unit-tested (it touches the real
/// filesystem); the Codable shape it reads/writes is pure and tested.
public enum WebSessionStore {
    /// The session file path: `~/.ghosthands/web-session.json`.
    public static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghosthands", isDirectory: true)
            .appendingPathComponent("web-session.json", isDirectory: false)
    }

    /// Load the active session, or nil when none is recorded / the file is
    /// unreadable or malformed (treated as "no session", never a crash).
    public static func load() -> WebSessionInfo? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(WebSessionInfo.self, from: data)
    }

    /// Persist `info`, creating `~/.ghosthands` if needed. Throws `relaunchFailed`
    /// when the file can't be written (so `web open` refuses rather than launch a
    /// session it can't record — which would orphan the process).
    public static func save(_ info: WebSessionInfo) throws {
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(info).write(to: path, options: .atomic)
        } catch {
            throw GhostHandsError.relaunchFailed(
                reason: "could not record the web session at \(path.path): "
                    + error.localizedDescription)
        }
    }

    /// Remove the session file (idempotent — no error if already gone).
    public static func clear() {
        try? FileManager.default.removeItem(at: path)
    }
}

// MARK: - Public entry points (impure thin — pure decisions above)

extension GhostHands {
    /// `web open [--headed] <url> [browser]` — launch an isolated throwaway browser
    /// session on an OS-chosen port, wait until a driveable page is listed, and
    /// persist the handle for subsequent verbs.
    ///
    /// `headed` is accepted for parity with agent-browser; the instance is ALWAYS
    /// launched headed (a visible window you can watch) — there is no headless mode
    /// by design. REFUSES (`sessionAlreadyOpen`) if a LIVE session already exists;
    /// a stale handle (dead pid) is overwritten.
    @MainActor
    public static func webOpen(url: String, browser: String?, headed: Bool)
        async throws -> WebSessionInfo {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        // One active session at a time: refuse over a LIVE one (don't orphan it).
        if let existing = WebSessionStore.load(), processAlive(existing.pid) {
            throw GhostHandsError.sessionAlreadyOpen(port: existing.port,
                                                     pid: existing.pid)
        } else {
            // A stale handle (dead pid) — clear it before launching a fresh one.
            WebSessionStore.clear()
        }

        let located = try locateBrowserBinary(browser ?? "Brave Browser")
        let launched = try await CDPLauncher.launch(binaryPath: located.binary, url: url)
        // Wait until a debuggable PAGE target is actually listed — the OBSERVED
        // readiness that makes "no external curl/poll" honest. On timeout, tear the
        // half-up instance down so we never leave an orphan behind a refuse.
        do {
            try await waitForDriveablePage(port: launched.port, app: located.appName)
        } catch {
            kill(launched.pid, SIGTERM)
            removeProfile(launched.profileDir)
            throw error
        }

        let info = WebSessionInfo(
            port: launched.port, pid: launched.pid, profileDir: launched.profileDir,
            browser: located.appName, binaryPath: located.binary, url: url)
        do {
            try WebSessionStore.save(info)
        } catch {
            // Couldn't record it → don't orphan the process; kill + clean, rethrow.
            kill(launched.pid, SIGTERM)
            removeProfile(launched.profileDir)
            throw error
        }
        return info
    }

    /// `web close` — terminate the managed session (plain SIGTERM, NEVER -9) and
    /// remove its throwaway profile. REFUSES (`noSession`) when none is open.
    /// Idempotent on the filesystem: the profile + handle are removed even if the
    /// process was already gone, so close never leaves a leftover.
    @MainActor
    public static func webClose() throws -> WebSessionInfo {
        guard let info = WebSessionStore.load() else {
            throw GhostHandsError.noSession
        }
        if processAlive(info.pid) {
            // SIGTERM, not SIGKILL — a clean shutdown lets the browser release its
            // profile lock; -9 is reserved away from us by the hard rails anyway.
            kill(info.pid, SIGTERM)
            // Brief bounded wait for the process to actually exit before we remove
            // its profile dir (avoids racing the browser's own teardown writes).
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, processAlive(info.pid) {
                usleep(100_000)
            }
        }
        removeProfile(info.profileDir)
        WebSessionStore.clear()
        return info
    }

    // MARK: Impure helpers

    /// True iff a process with `pid` is still alive. `kill(pid, 0)` sends no
    /// signal — it just probes existence (0 = alive / EPERM; ESRCH = gone).
    static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM   // exists but owned by another user (not our case)
    }

    /// Remove a throwaway profile dir best-effort (and its parent `ghosthands-cdp`
    /// wrapper when empty). Never throws — close must not fail on a cleanup hiccup.
    static func removeProfile(_ profileDir: String) {
        try? FileManager.default.removeItem(atPath: profileDir)
    }

    /// Locate a browser executable by app name WITHOUT requiring it to be running
    /// (a fresh session usually launches a not-yet-open browser). Prefers a running
    /// instance's bundle (the exact current install); else finds the installed
    /// `.app` by name under /Applications (or ~/Applications). Throws
    /// `relaunchFailed` when nothing matches — never spawns a guessed binary.
    @MainActor
    static func locateBrowserBinary(_ name: String)
        throws -> (binary: String, appName: String) {
        if let target = try? Target.resolve(name),
           let bundleURL = target.app.bundleURL,
           let bundle = Bundle(url: bundleURL),
           let exec = bundle.executableURL {
            return (exec.path, target.name)
        }
        let candidates = [
            "/Applications/\(name).app",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/\(name).app").path,
        ]
        for path in candidates {
            if let bundle = Bundle(path: path), let exec = bundle.executableURL {
                return (exec.path, name)
            }
        }
        throw GhostHandsError.relaunchFailed(
            reason: "could not locate the \(name.debugDescription) app to open a "
                + "session — install it or pass an exact app name")
    }

    /// Poll `/json/list` until a debuggable PAGE target (one with a non-empty
    /// `webSocketDebuggerUrl`) appears, or the deadline elapses. A listed page IS
    /// driveable (you can `Runtime.evaluate` on it), so this is the honest
    /// "session is ready" gate. Bounded — a browser that never lists a page raises
    /// `cdpTransport` rather than spinning forever.
    @MainActor
    static func waitForDriveablePage(port: Int, app: String,
                                     deadline: TimeInterval = 12) async throws {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if let targets = try? await CDPDiscovery.list(port: port, app: app),
               targets.contains(where: { !$0.webSocketDebuggerUrl.isEmpty }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw GhostHandsError.cdpTransport(
            reason: "session opened on port \(port) but no driveable page target "
                + "appeared within \(Int(deadline))s")
    }
}
