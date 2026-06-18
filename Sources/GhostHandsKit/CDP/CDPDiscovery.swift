import Foundation

/// The IMPURE discovery probes: loopback-hardcoded HTTP GETs against an
/// already-open DevTools port. NO socket connect here, NO launch/relaunch — this
/// only reads `/json/version` (the silent fallback probe) and `/json/list` (the
/// full tab list, incl. background tabs) over `URLSession`.
///
/// SECURITY: every URL is formatted as `http://127.0.0.1:<port>/…` — loopback by
/// construction, so the GET side can never reach a non-loopback host. (The
/// WebSocket side is separately gated by `CDPSession.open`'s `isLoopback` check.)
///
/// NOT unit-tested (it does real network IO); exercised only in manual
/// live-verify against an isolated browser on a debug port, per the design doc.
public enum CDPDiscovery {
    /// A short timeout so an unreachable port fails fast (the analog of
    /// Install.swift's bounded Process drain, but for URLSession).
    static let timeout: TimeInterval = 10

    private static func loopbackURL(port: Int, path: String) -> URL? {
        URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    /// True iff a DevTools endpoint answers on `127.0.0.1:<port>` — the SILENT
    /// fallback probe used by the `auto` lens. GETs `/json/version`; true on a 2xx
    /// with a decodable JSON-object body, false on ANY error/timeout/non-2xx. NEVER
    /// throws — a closed port must fall back to AX without surfacing an error.
    public static func isPortOpen(_ port: Int) async -> Bool {
        guard let url = loopbackURL(port: port, path: "/json/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return false }
        // A real DevTools endpoint returns a JSON object; anything else (a
        // captive portal, a different service on the port) is treated as closed.
        return (try? CDPTarget.decodeVersion(data)) != nil
    }

    /// List the page targets (tabs) on `127.0.0.1:<port>` via `/json/list`. This
    /// is the deepest immediate win: the FULL tab list including background tabs,
    /// which AX cannot see. Throws `cdpPortClosed` when the port is unreachable
    /// (so a forced `--cdp` REFUSES) and `cdpTransport` on a malformed body. The
    /// raw `Data` is handed to the PURE `CDPTarget.decodeList`.
    public static func list(port: Int, app: String) async throws -> [CDPTarget] {
        guard let url = loopbackURL(port: port, path: "/json/list") else {
            throw GhostHandsError.cdpPortClosed(app: app, port: port)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GhostHandsError.cdpPortClosed(app: app, port: port)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw GhostHandsError.cdpPortClosed(app: app, port: port)
        }
        return try CDPTarget.decodeList(data)
    }

    /// The browser's top-level `webSocketDebuggerUrl` (from `/json/version`),
    /// used to open a session for a `Runtime.evaluate` page digest. Throws
    /// `cdpPortClosed` when unreachable. Honest: returns nil when the endpoint
    /// answers but advertises no browser-level socket.
    public static func browserWebSocketURL(port: Int, app: String) async throws -> String? {
        guard let url = loopbackURL(port: port, path: "/json/version") else {
            throw GhostHandsError.cdpPortClosed(app: app, port: port)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GhostHandsError.cdpPortClosed(app: app, port: port)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw GhostHandsError.cdpPortClosed(app: app, port: port)
        }
        return try CDPTarget.decodeVersion(data)["webSocketDebuggerUrl"]
    }
}
