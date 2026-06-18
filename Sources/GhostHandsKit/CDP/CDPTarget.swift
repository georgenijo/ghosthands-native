import Foundation

/// One DevTools target as listed by `/json/list` — a page, a worker, etc. We
/// keep only `page` targets (the browsable tabs incl. background ones), mirroring
/// the Python `t.get("type","page")` default + page filter.
///
/// PURE: `decodeList`/`decodeVersion`/`isLoopback` take `Data`/`String` in,
/// model out, and throw/return on malformed — no IO, no socket. This MIRRORS
/// `Install.mountPoint(fromAttachPlist:)` (Data in, model out, nil/throw on
/// malformed) so it is hermetically unit-tested on fabricated bytes.
public struct CDPTarget: Sendable, Equatable {
    /// The DevTools target id (stable for the life of the tab).
    public let id: String
    /// The page URL.
    public let url: String
    /// The page title (empty when the tab exposes none).
    public let title: String
    /// The target type — defaulted to "page" when `/json/list` omits it, mirroring
    /// the Python `t.get("type","page")`.
    public let type: String
    /// The per-target WebSocket debugger URL. Loopback-guarded before any connect.
    public let webSocketDebuggerUrl: String

    public init(id: String, url: String, title: String, type: String,
                webSocketDebuggerUrl: String) {
        self.id = id
        self.url = url
        self.title = title
        self.type = type
        self.webSocketDebuggerUrl = webSocketDebuggerUrl
    }

    // MARK: - Pure decode: /json/list → [CDPTarget]

    /// Decode a `/json/list` body into the page targets.
    ///
    /// Requires a top-level JSON ARRAY of objects; maps each entry, **filters to
    /// `type == "page"`** (a missing `type` defaults to "page", so a page-shaped
    /// entry without the key is kept; a `service_worker`/`iframe`/`background_page`
    /// is dropped). Throws `cdpTransport` on non-JSON / non-array / structurally
    /// malformed input — never a leaked `NSError`, never a fabricated entry. An
    /// honest empty array decodes to `[]` (no throw).
    public static func decodeList(_ data: Data) throws -> [CDPTarget] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GhostHandsError.cdpTransport(reason: "/json/list is not JSON")
        }
        guard let array = root as? [[String: Any]] else {
            throw GhostHandsError.cdpTransport(
                reason: "/json/list is not an array of target objects")
        }
        var out: [CDPTarget] = []
        for entry in array {
            // Missing type defaults to "page" (Python parity); filter to pages.
            let type = (entry["type"] as? String) ?? "page"
            guard type == "page" else { continue }
            // An entry that claims to be a page but carries no id is malformed —
            // refuse rather than synthesise an empty id.
            guard let id = entry["id"] as? String else {
                throw GhostHandsError.cdpTransport(
                    reason: "/json/list page entry has no id")
            }
            out.append(CDPTarget(
                id: id,
                url: (entry["url"] as? String) ?? "",
                title: (entry["title"] as? String) ?? "",
                type: type,
                webSocketDebuggerUrl: (entry["webSocketDebuggerUrl"] as? String) ?? ""))
        }
        return out
    }

    // MARK: - Pure decode: /json/version (probe only)

    /// A tolerant decode of `/json/version` into a `[String:String]` (Browser,
    /// webSocketDebuggerUrl, …). Used only by discovery's port probe to confirm a
    /// real DevTools endpoint answered. Returns the string-valued keys; throws
    /// `cdpTransport` only when the body is not a JSON object at all.
    public static func decodeVersion(_ data: Data) throws -> [String: String] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GhostHandsError.cdpTransport(reason: "/json/version is not JSON")
        }
        guard let dict = root as? [String: Any] else {
            throw GhostHandsError.cdpTransport(
                reason: "/json/version is not a JSON object")
        }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    // MARK: - Security: loopback-only guard (PURE)

    /// The SECURITY gate, unit-testable: true iff `wsURL`'s host is loopback —
    /// `127.0.0.1`, `::1`, or `localhost`. A non-loopback `webSocketDebuggerUrl`
    /// (e.g. a LAN IP or a hostname) returns false and is REFUSED before any
    /// socket is created. Parses via `URLComponents`; an unparseable URL with no
    /// host returns false (refuse-on-unknown).
    public static func isLoopback(_ wsURL: String) -> Bool {
        guard let host = URLComponents(string: wsURL)?.host else { return false }
        // `URLComponents` brackets an IPv6 host literal as "[::1]"; strip them.
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        return bare == "127.0.0.1" || bare == "::1" || bare == "localhost"
    }
}
