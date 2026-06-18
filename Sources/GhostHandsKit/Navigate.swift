import AppKit
import ApplicationServices
import AXorcist
import Foundation

// GhostHands NAVIGATE tier — drive a browser to a URL, then HONESTLY confirm the
// page changed by reading the post-load AXWebArea's document URL/title back.
//
// `navigate <url> [browser]` actuates the load with `open -a <browser> <url>`
// (the same Foundation.Process idiom Install uses), settles, then RE-READS the
// browser's FOCUSED-WINDOW AXWebArea off a fresh app element and decides the
// verdict from THAT read-back alone — never from `open`'s exit status.
//
// We scope the read-back to the app's FOCUSED window (then its MAIN window) —
// the window `open -a` raised the load into — rather than walking `windows()`
// in order, so a pre-existing window already showing the requested host cannot
// be mistaken for the page THIS navigation produced.
//
// Honesty contract (mirrors install / web read):
//   - REFUSE (throw, exit nonzero, NOTHING claimed) when: the URL is malformed
//     (the pure `NavURL.normalize` gate), the `[browser]` spec is unresolved /
//     ambiguous (`Target.resolve`), or AX is not trusted.
//   - VERIFIED only when, AFTER the load + settle, the focused-window AXWebArea's
//     read-back URL host matches the requested host (and path when a specific
//     path was requested). A 0-status `open` NEVER auto-upgrades to verified —
//     the verdict signature deliberately omits the open exit status.
//   - DISPATCHED-UNVERIFIED (exit 0, the word "unverified" in the line, never
//     "navigated"/"success") when the load issued but the AXWebArea is not
//     exposed / its URL is nil / the read-back host does not (yet) match (a page
//     still loading, an SPA client-side route, or a redirect we can't confirm).
//
// V1 SCOPE: actuate via `open` + honest AX read-back. The omnibox-driven version
// (type the URL into the address-bar AXTextField + AXPress Enter, then read back)
// is a FUTURE upgrade once this key verb exists.
//
// PURITY: URL validation/normalization (`NavURL`) and the verdict (`NavVerdict`)
// are pure enums tested hermetically on fabricated strings — never a live
// browser, never `open`, never AX. The live orchestration below is the only
// impure part, and even its verdict step is the pure `NavVerdict.decide`.

// MARK: - Pure: URL validation / normalization

/// The refuse-on-malformed URL gate, PURE (no Process, no AX). Trims, prepends
/// `https://` to a bare host/path, and REFUSES when the result has no parseable
/// host. Unit-tested on fabricated strings.
public enum NavURL {
    public enum Result: Sendable, Equatable {
        /// A parseable URL with a host (or a file URL with a path).
        case ok(URL)
        /// The raw string could not be normalized into a host-bearing URL.
        case malformed(String)

        public static func == (lhs: Result, rhs: Result) -> Bool {
            switch (lhs, rhs) {
            case let (.ok(u1), .ok(u2)): return u1 == u2
            case let (.malformed(s1), .malformed(s2)): return s1 == s2
            default: return false
            }
        }
    }

    /// True iff `raw` (already trimmed) begins with a `scheme://` or a
    /// scheme-only `scheme:` prefix — i.e. the caller already named a scheme, so
    /// we keep it as-is rather than prepending https. A scheme is letters/digits/
    /// `+`/`-`/`.` starting with a letter, per RFC 3986.
    static func hasScheme(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        let scheme = raw[raw.startIndex..<colon]
        guard let first = scheme.first, first.isLetter, !scheme.isEmpty else { return false }
        // A bare "localhost:3000" looks scheme-like but is really host:port — the
        // part after the colon is all digits and there is no "//". Treat that as a
        // bare host so we prepend https. A real scheme is followed by "//" OR by a
        // non-numeric opaque part (mailto:, file:/path).
        let afterColon = raw[raw.index(after: colon)...]
        if afterColon.hasPrefix("//") { return true }
        // "host:port" → all digits after the colon, no slashes → NOT a scheme.
        if !afterColon.isEmpty, afterColon.allSatisfy({ $0.isNumber }) { return false }
        // Every scheme char must be valid; otherwise it isn't a scheme prefix.
        let schemeOK = scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
        return schemeOK
    }

    /// Normalize a raw user URL string into a host-bearing `URL`, or refuse.
    ///
    /// Rule: trim whitespace; if it already names a scheme keep it; else prepend
    /// `https://` (so `example.com`, `localhost:3000`, `example.com/foo` all
    /// resolve). REFUSE when, after that, `URLComponents` cannot parse it OR there
    /// is no host (and it is not a file URL carrying a path).
    public static func normalize(_ raw: String) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .malformed(raw) }

        let candidate = hasScheme(trimmed) ? trimmed : "https://" + trimmed

        guard let comps = URLComponents(string: candidate), let url = comps.url else {
            return .malformed(raw)
        }

        // A file URL is valid when it carries a path even without a host.
        if (comps.scheme?.lowercased() == "file"), !comps.path.isEmpty {
            return .ok(url)
        }

        // Otherwise we require a non-empty host (the "http://" / "https://[" cases
        // with no host are the refuse gate).
        guard let host = comps.host, !host.isEmpty else {
            return .malformed(raw)
        }
        return .ok(url)
    }

    /// The host of `url`, lowercased with a leading `www.` stripped — the
    /// normalized form both sides of the verdict compare on. nil when the URL has
    /// no host (a path-only file URL).
    public static func host(of url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let lowered = host.lowercased()
        if lowered.hasPrefix("www.") { return String(lowered.dropFirst(4)) }
        return lowered
    }

    /// The normalized path key of `url`: its path with runs of `/` collapsed to a
    /// single slash and a trailing slash stripped (so `/foo`, `/foo/`, and
    /// `//foo` are the same key, and `/` and `""` both reduce to the empty "no
    /// specific path" key). Collapsing duplicate slashes lets a sloppily-typed
    /// `example.com//docs` request still match a landed `/docs`.
    public static func pathKey(of url: URL) -> String {
        var collapsed = ""
        var lastWasSlash = false
        for ch in url.path {
            if ch == "/" {
                if lastWasSlash { continue }
                lastWasSlash = true
            } else {
                lastWasSlash = false
            }
            collapsed.append(ch)
        }
        var p = collapsed
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p == "/" ? "" : p
    }
}

// MARK: - Pure: the navigate verdict

/// The pure verdict for `navigate`, mirroring `ValueVerdict` / `Install.VerifyDecision`.
///
/// This is the honesty core: it decides VERIFIED vs DISPATCHED-UNVERIFIED from
/// the FABRICATED before/after page signals — the requested URL's host/path and
/// the post-load AXWebArea's read-back url/title — and NEVER sees `open`'s exit
/// status. "open returned 0" is therefore, by construction, not proof: a 0-status
/// load with a nil `landedURL` is still `.dispatchedUnverified`.
public enum NavVerdict {
    public enum Result: Sendable, Equatable {
        /// The post-load AXWebArea read back a URL whose host matches the request
        /// (and path when a specific path was requested). `evidence` quotes the
        /// landed URL (and title when present).
        case verified(evidence: String)
        /// The load issued but the landed page could not be confirmed to be the
        /// requested site — honest under-claim, never a success claim.
        case dispatchedUnverified(reason: String)

        public static func == (lhs: Result, rhs: Result) -> Bool {
            switch (lhs, rhs) {
            case let (.verified(e1), .verified(e2)): return e1 == e2
            case let (.dispatchedUnverified(r1), .dispatchedUnverified(r2)): return r1 == r2
            default: return false
            }
        }
    }

    /// Decide the verdict from the read-back facts ALONE.
    ///
    /// - `requestedHost`: the normalized host (lowercased, `www.` stripped) of the
    ///   URL the caller asked for — the spine of the match.
    /// - `requestedPath`: the normalized pathKey requested ("" = no specific path,
    ///   so a host match alone is enough; a non-empty path must also match).
    /// - `landedURL`: the AXWebArea's read-back URL (nil = no web area / no
    ///   `AXURL` / `AXDocument` exposed — cannot confirm).
    /// - `landedTitle`: the AXWebArea's title (secondary corroboration only;
    ///   host match is the spine — a benign title never upgrades a host mismatch).
    ///
    /// VERIFIED iff `landedURL`'s host == `requestedHost` AND (the requested path
    /// is empty OR the landed pathKey == the requested path). Otherwise
    /// DISPATCHED-UNVERIFIED with a reason.
    public static func decide(requestedHost: String?,
                              requestedPath: String,
                              landedURL: URL?,
                              landedTitle: String?) -> Result {
        // No read-back URL ⇒ the AXWebArea / its URL is not exposed. The load may
        // well have landed, but we cannot confirm it — the honest under-claim.
        guard let landedURL else {
            return .dispatchedUnverified(
                reason: "no readable page URL (AXWebArea not exposed or URL nil)")
        }
        guard let requestedHost else {
            // We have no host to match against (a path-only file URL request, say);
            // without a host spine we cannot honestly claim the page is the target.
            return .dispatchedUnverified(reason: "no host to match against requested URL")
        }
        guard let landedHost = NavURL.host(of: landedURL) else {
            return .dispatchedUnverified(
                reason: "landed URL \(landedURL.absoluteString.debugDescription) has no host")
        }

        let titleSuffix = (landedTitle?.isEmpty == false)
            ? " (title \(landedTitle!.debugDescription))" : ""

        // HOST IS THE SPINE. A mismatch (a redirect / SSO / interstitial we can't
        // confirm is the target) is NEVER faked verified, regardless of title.
        guard landedHost == requestedHost else {
            return .dispatchedUnverified(
                reason: "landed on \(landedHost.debugDescription) "
                    + "(\(landedURL.absoluteString.debugDescription)), not the requested host "
                    + "\(requestedHost.debugDescription)")
        }

        // Host matches. When a SPECIFIC path was requested, it must match too;
        // when no path was requested, a host match is the verification.
        if !requestedPath.isEmpty {
            let landedPath = NavURL.pathKey(of: landedURL)
            guard landedPath == requestedPath else {
                return .dispatchedUnverified(
                    reason: "host matched but landed path \(landedPath.debugDescription) "
                        + "≠ requested \(requestedPath.debugDescription) "
                        + "(\(landedURL.absoluteString.debugDescription))")
            }
        }

        return .verified(evidence: "landed \(landedURL.absoluteString)\(titleSuffix)")
    }
}

// MARK: - Live orchestration

extension GhostHands {
    /// The result of a navigate that issued the load (verified OR dispatched-
    /// unverified). A REFUSE never produces an outcome — it throws before/without
    /// confirming anything.
    public struct NavigateOutcome: Sendable {
        /// The resolved browser's localized name (the `-a` value `open` launched into).
        public let app: String
        /// The normalized URL we asked the browser to load.
        public let requestedURL: String
        /// The AXWebArea's read-back URL (present when a page surface was readable).
        public let landedURL: String?
        /// The AXWebArea's read-back title (best-effort corroboration).
        public let landedTitle: String?
        /// True only when the read-back host (and path when requested) matched the request.
        public let verified: Bool
        /// The human evidence (verified) or the honest unverified reason.
        public let evidence: String?
        /// True when `[browser]` was OMITTED and we auto-picked a running Chromium.
        public let autoPicked: Bool
    }

    /// Ordered preference list of RUNNING Chromium browsers to auto-pick when
    /// `[browser]` is omitted. Brave-first (matches the project's local-brain
    /// note and the existing `web read Brave` examples), then the common rest.
    public static let chromiumPreference = [
        "Brave Browser", "Google Chrome", "Chromium", "Arc", "Microsoft Edge",
    ]

    /// Navigate `url` in `browser` (a `Target.resolve` spec) — or, when `browser`
    /// is nil, the first RUNNING Chromium from `chromiumPreference` — then verify
    /// the landed page off the FOCUSED-WINDOW AXWebArea.
    ///
    /// We resolve the browser FIRST (so we read the verify back from the SAME app
    /// we launch into), then actuate the load with `open -a <name> <url>`, settle
    /// (a touch longer than `web read` since a real navigation has network
    /// latency), wake + re-walk a FRESH app element, find the live AXWebArea in
    /// the browser's FOCUSED window (`focusedWebArea`), read its URL/title, and
    /// drive the pure `NavVerdict`.
    @MainActor
    public static func navigate(url rawURL: String,
                                browser: String?,
                                settle: TimeInterval = 1.2) throws -> NavigateOutcome {
        // REFUSE on a malformed URL FIRST — the pure normalize gate (never touch
        // `open`). This runs BEFORE the AX gate so a malformed URL always gets the
        // precise `.malformedURL` message regardless of AX-permission state (a
        // malformed address is a usage error that needs no AX tree to diagnose).
        let normalized: URL
        switch NavURL.normalize(rawURL) {
        case let .ok(u): normalized = u
        case .malformed: throw GhostHandsError.malformedURL(rawURL)
        }
        let urlString = normalized.absoluteString

        // AX gate (mirrors web read) — the read-back verify needs the AX tree.
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }

        // Resolve the browser (explicit spec → Target.resolve; omitted → auto-pick
        // a running Chromium). Resolution failure REFUSES (never falls back to
        // open's OS default — we could not then verify against a known app).
        let target: Target
        let autoPicked: Bool
        if let browser {
            target = try Target.resolve(browser)
            autoPicked = false
        } else {
            target = try resolveDefaultChromium()
            autoPicked = true
        }

        // --- actuate the load: open -a <browser name> <url> (the Install idiom) ---
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", target.name, urlString]
        let openErr = Pipe()
        open.standardError = openErr
        do {
            try open.run()
        } catch {
            // A launch failure of `open` itself is a hard refuse — nothing issued.
            throw GhostHandsError.openFailed(
                reason: "could not run open: \(error.localizedDescription)")
        }
        // Drain stderr BEFORE waitUntilExit (the Install deadlock guard).
        let openErrData = openErr.fileHandleForReading.readDataToEndOfFile()
        open.waitUntilExit()
        // A nonzero `open` status is NOT a refuse and NOT proof — at most a hint.
        // Honesty comes from the read-back below. (We keep the stderr only to
        // surface it as a reason if the page also can't be read.)
        let openHint = String(data: openErrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = open.terminationStatus

        // --- settle, then RE-READ the landed page off a FRESH app element ---
        // The load is async (network latency); a brand-new AXUIElement does not
        // inherit AXManualAccessibility, so wake it again before walking.
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        let fresh = Element(AXUIElementCreateApplication(target.pid))
        WebWalker.wakeAccessibility(fresh)

        let webArea = focusedWebArea(under: fresh)
        let landedURL = readPageURL(webArea)
        let landedTitle = webArea?.title()

        let requestedHost = NavURL.host(of: normalized)
        let requestedPath = NavURL.pathKey(of: normalized)

        switch NavVerdict.decide(requestedHost: requestedHost,
                                 requestedPath: requestedPath,
                                 landedURL: landedURL,
                                 landedTitle: landedTitle) {
        case let .verified(evidence):
            return NavigateOutcome(app: target.name, requestedURL: urlString,
                                   landedURL: landedURL?.absoluteString,
                                   landedTitle: landedTitle,
                                   verified: true, evidence: evidence,
                                   autoPicked: autoPicked)
        case let .dispatchedUnverified(reason):
            // If we have NO read-back AND `open` printed something, fold that hint
            // into the reason so the human has a thread to pull — still unverified.
            let folded: String
            if landedURL == nil, let hint = openHint, !hint.isEmpty {
                folded = "\(reason); open said: \(hint)"
            } else {
                folded = reason
            }
            return NavigateOutcome(app: target.name, requestedURL: urlString,
                                   landedURL: landedURL?.absoluteString,
                                   landedTitle: landedTitle,
                                   verified: false, evidence: folded,
                                   autoPicked: autoPicked)
        }
    }

    /// Auto-pick the first RUNNING browser from `chromiumPreference` that
    /// `Target.resolve` finds. REFUSE (`.appNotFound`) when none is running — we
    /// never silently fall back to a non-Chromium or to `open`'s OS default,
    /// because we could not then verify the load against a known app element.
    @MainActor
    private static func resolveDefaultChromium() throws -> Target {
        for name in chromiumPreference {
            if let t = try? Target.resolve(name) { return t }
        }
        throw GhostHandsError.appNotFound("<a running Chromium browser>")
    }

    /// Read the current document URL off an AXWebArea element: the AXURL
    /// convenience reader first, falling back to the AXDocument attribute (some
    /// Chromium builds expose AXDocument but not AXURL). Returns nil when neither
    /// is present (the honest "can't read the page URL" signal).
    @MainActor
    static func readPageURL(_ webArea: Element?) -> URL? {
        guard let webArea else { return nil }
        if let url = webArea.url() { return url }
        // Fallback: AXDocument is a URL/path string.
        if let raw = webArea.rawAttributeValue(named: AXAttributeNames.kAXDocumentAttribute),
           let s = axString(raw), !s.isEmpty {
            return URL(string: s)
        }
        return nil
    }

    /// Return the live `AXWebArea` `Element` of the browser's FOCUSED page, or nil.
    ///
    /// HONESTY (the verify must read the page THIS navigation surfaced, not a
    /// stale same-host tab in some other window): we scope the walk to the app's
    /// FOCUSED window (then its MAIN window), because `open -a` raises the target
    /// window to focused/main, so the active tab lives there — NOT necessarily in
    /// the first-enumerated `windows()[0]`, which may be a pre-existing window
    /// already showing the requested host. Walking `windows()` in order (the old
    /// `firstWebArea`) could read that stale window and falsely report verified.
    ///
    /// Within the chosen window we return the FIRST AXWebArea — in Chromium a
    /// browser window's a11y tree exposes the ACTIVE tab's web area as its
    /// readable page surface (background tabs are not built until visited), so the
    /// first web area in the focused window is the active page, not a stale tab.
    ///
    /// LAST-RESORT fallback: if AX exposes NEITHER a focused NOR a main window (a
    /// beat after the raise, before the flags settle), we scan all windows in
    /// order. This can read a wrong/stale window — but the host-spine in
    /// `NavVerdict.decide` still gates the verdict, so the worst case is a
    /// mismatched read that lands DISPATCHED-UNVERIFIED. It never fakes a success
    /// on `open`'s exit status, and it never reads a window OTHER than the focused
    /// one once AX has flagged focus.
    @MainActor
    static func focusedWebArea(under appRoot: Element) -> Element? {
        // Prefer the focused window, then the main window — that is where the
        // freshly-loaded/raised tab lives. De-dup so we don't walk the same
        // window twice when focused == main.
        var preferred: [Element] = []
        for w in [appRoot.focusedWindow(), appRoot.mainWindow()] {
            if let w, !preferred.contains(w) { preferred.append(w) }
        }
        for window in preferred {
            if let hit = webAreaInWindow(window) { return hit }
        }
        // Last resort: AX has not (yet) flagged a focused/main window. Scan all
        // windows in order. (Honesty still rests on the host-match verdict.)
        for window in appRoot.windows() ?? [] {
            if let hit = webAreaInWindow(window) { return hit }
        }
        return nil
    }

    /// Depth-bounded live walk of a SINGLE window, returning its first `AXWebArea`,
    /// or nil. Same shape as `WebWalker.node` (raw `children(strict:)` + a visited
    /// set + a depth cap).
    @MainActor
    private static func webAreaInWindow(_ window: Element) -> Element? {
        var visited = Set<Element>()
        func walk(_ element: Element, depth: Int) -> Element? {
            if element.role() == WebDigest.webAreaRole { return element }
            guard depth < WebWalker.maxDepth, !visited.contains(element) else { return nil }
            visited.insert(element)
            for child in element.children(strict: true) ?? [] {
                if let hit = walk(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        return walk(window, depth: 0)
    }
}
