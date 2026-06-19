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

// MARK: - --target page selection (PURE)

/// Choose WHICH debuggable page/renderer a CDP verb drives, from `/json/list`.
/// The default (no selector) keeps the historical behavior — the FIRST debuggable
/// page — so every existing call site is unchanged; `--target` adds the ability to
/// aim at a specific renderer, which matters for multi-window Electron apps where
/// `/json/list` reports several page targets and the first is not the one you want.
///
/// PURE: takes the decoded `[CDPTarget]` + an optional selector, returns the chosen
/// target (or nil → the caller REFUSES `cdpTargetNotFound`). No IO — unit-tested on
/// fabricated target lists, mirroring `LocatorSpec` / `WebFind` ranking.
public enum CDPTargetPick {
    /// What `--target <n|title>` resolves to: an all-digit arg is a 1-based INDEX
    /// among the debuggable pages; anything else is a case-insensitive SUBSTRING of
    /// a page's title OR url.
    public enum Selector: Sendable, Equatable {
        case index(Int)
        case match(String)
        /// An EXACT DevTools target id — the stable handle `see` persists so `act`
        /// reattaches to the identical renderer (not a fuzzy title/index that could
        /// drift). No match → nil (the caller refuses).
        case id(String)
    }

    /// The chosen page plus the reporting facts a `--target` pick surfaces (a pick
    /// is never silent): the target, its 1-based position among debuggable pages,
    /// and how many pages matched (so the caller can hint at `--target N` to choose
    /// another on a multi-match).
    public struct Choice: Sendable, Equatable {
        public let target: CDPTarget
        public let index: Int
        public let matchCount: Int

        public init(target: CDPTarget, index: Int, matchCount: Int) {
            self.target = target
            self.index = index
            self.matchCount = matchCount
        }
    }

    /// Parse a raw `--target` argument: an all-digit value (≥1) → `.index`, else a
    /// `.match` substring. An empty/whitespace value falls to `.match("")`, which
    /// matches every page (the caller still picks the first) — never a crash.
    public static func parse(_ raw: String) -> Selector {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed), n >= 1 { return .index(n) }
        return .match(trimmed)
    }

    /// Choose among the DEBUGGABLE page targets (those with a non-empty
    /// `webSocketDebuggerUrl` — the only ones we can attach to). Returns nil when
    /// nothing matches, so the caller REFUSES rather than drive an arbitrary page:
    /// - no selector → the FIRST debuggable page (historical default).
    /// - `.index(n)` → the n-th debuggable page (1-based); out of range → nil.
    /// - `.match(q)` → the first page whose title OR url contains `q`
    ///   (case-insensitive); no match → nil. `matchCount` reports how many matched.
    public static func choose(_ targets: [CDPTarget], _ selector: Selector?) -> Choice? {
        let pages = targets.filter { !$0.webSocketDebuggerUrl.isEmpty }
        guard !pages.isEmpty else { return nil }
        switch selector {
        case .none:
            return Choice(target: pages[0], index: 1, matchCount: pages.count)
        case let .index(n):
            guard n >= 1, n <= pages.count else { return nil }
            return Choice(target: pages[n - 1], index: n, matchCount: pages.count)
        case let .match(q):
            let needle = q.lowercased()
            func hit(_ t: CDPTarget) -> Bool {
                t.title.lowercased().contains(needle) || t.url.lowercased().contains(needle)
            }
            let count = pages.filter(hit).count
            guard let i = pages.firstIndex(where: hit) else { return nil }
            return Choice(target: pages[i], index: i + 1, matchCount: count)
        case let .id(wanted):
            guard let i = pages.firstIndex(where: { $0.id == wanted }) else { return nil }
            return Choice(target: pages[i], index: i + 1, matchCount: 1)
        }
    }

    /// A short human label for a target's report line — its title, or its url when
    /// untitled, or a placeholder. Used in the `cdpTargetNotFound` listing.
    public static func label(_ t: CDPTarget) -> String {
        if !t.title.isEmpty { return t.title }
        if !t.url.isEmpty { return t.url }
        return "(untitled page)"
    }
}
