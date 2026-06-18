import Foundation

// GhostHands WEB EXTRACT tier — first-class no-JS read verbs for browser surfaces
// (CDP, issue #11). Routine multi-element extraction (HN top-5, BBC headlines, a
// Maps feed) used to require `web eval`; these make it a plain verb:
//
//   web text  "<css>" [--all]      — visible text of the matched element(s)
//   web attr  "<css>" <name> [--all] — an attribute of the matched element(s)
//   web count "<css>"              — number of matches (0 is an honest answer)
//   web read  --in "<css>"         — scope the page digest to a container
//
// HONESTY CONTRACT (same as the rest of the web tier): these are READS — they
// report exactly what the DOM exposes, never a fabricated value. An INVALID CSS
// selector or (for text/attr) a selector matching NOTHING is a REFUSE
// (`selectorNotFound`), distinct from `count`'s honest `0`. A `--ax` lens REFUSES
// (`selectorNeedsCDP`) — a CSS selector has no AX equivalent.
//
// PURITY: the per-verb probe is built here (PURE string), and the reply is shaped
// by PURE functions over a FABRICATED `[String: Any]`, so the keep/refuse rules
// are hermetically unit-tested with no socket and no browser. The only impure step
// is the single `Runtime.evaluate` in the `GhostHands.web*` entry points.

// MARK: - PURE: probe expressions + reply shaping

/// The pure extraction model: per-verb probe JS + the shaping of its reply into a
/// typed result (or a refuse decision). Mirrors `WebHtml` / `WebActuate`.
public enum WebExtract {
    /// `web text` probe: collect each match's visible text (`innerText`, falling
    /// back to `textContent`), trimmed. Returns `{ ok, texts: [string] }`; `ok` is
    /// false ONLY when the selector is syntactically invalid (querySelectorAll
    /// threw). An empty `texts` means a valid selector that matched nothing.
    public static func textProbeExpression(selector: String) -> String {
        let sel = WebActuate.jsonStringLiteral(selector)
        return """
        (() => {
          let els;
          try { els = document.querySelectorAll(\(sel)); } catch (e) { return { ok: false }; }
          const texts = [];
          for (const el of els) {
            texts.push(((el.innerText || el.textContent || '')).trim());
          }
          return { ok: true, texts };
        })()
        """
    }

    /// `web attr` probe: collect each match's `getAttribute(name)` (a string, or
    /// null when the element lacks the attribute — reported honestly as absent, not
    /// an empty string). Returns `{ ok, values: [string|null] }`.
    public static func attrProbeExpression(selector: String, name: String) -> String {
        let sel = WebActuate.jsonStringLiteral(selector)
        let attr = WebActuate.jsonStringLiteral(name)
        return """
        (() => {
          let els;
          try { els = document.querySelectorAll(\(sel)); } catch (e) { return { ok: false }; }
          const values = [];
          for (const el of els) {
            const v = el.getAttribute(\(attr));
            values.push(v === null ? null : v);
          }
          return { ok: true, values };
        })()
        """
    }

    /// `web count` probe: `{ ok, count }`. `ok` false ⇒ invalid selector.
    public static func countProbeExpression(selector: String) -> String {
        let sel = WebActuate.jsonStringLiteral(selector)
        return """
        (() => {
          try { return { ok: true, count: document.querySelectorAll(\(sel)).length }; }
          catch (e) { return { ok: false }; }
        })()
        """
    }

    /// The shaped result of a text/attr extraction — an ordered list of values (one
    /// per match). For `attr`, an absent attribute is `nil` (honest "not present").
    public struct Extracted: Sendable, Equatable {
        public let values: [String?]
        public init(values: [String?]) { self.values = values }
        /// The non-nil values rendered for printing (nil → empty string).
        public var rendered: [String] { values.map { $0 ?? "" } }
        public var count: Int { values.count }
    }

    /// Shape a `web text` reply. Throws `selectorNotFound` on an invalid selector
    /// (`ok:false`) OR a valid selector that matched nothing — you asked for an
    /// element's text and there is none. Otherwise the per-match texts in order.
    public static func shapeText(_ dict: [String: Any], selector: String, app: String)
        throws -> Extracted {
        guard WebActuate.boolValue(dict["ok"]) else {
            throw GhostHandsError.selectorNotFound(selector: selector, app: app)
        }
        let texts = (dict["texts"] as? [Any])?.map { $0 as? String } ?? []
        guard !texts.isEmpty else {
            throw GhostHandsError.selectorNotFound(selector: selector, app: app)
        }
        return Extracted(values: texts)
    }

    /// Shape a `web attr` reply. Same refuse rules as `shapeText`; a match that
    /// lacks the attribute is a `nil` value (not a refuse — the element exists).
    public static func shapeAttr(_ dict: [String: Any], selector: String, app: String)
        throws -> Extracted {
        guard WebActuate.boolValue(dict["ok"]) else {
            throw GhostHandsError.selectorNotFound(selector: selector, app: app)
        }
        // A JS `null` decodes to NSNull; map it to a Swift nil (absent attribute).
        guard let raw = dict["values"] as? [Any], !raw.isEmpty else {
            throw GhostHandsError.selectorNotFound(selector: selector, app: app)
        }
        let values: [String?] = raw.map { ($0 is NSNull) ? nil : ($0 as? String) }
        return Extracted(values: values)
    }

    /// Shape a `web count` reply. Throws `selectorNotFound` ONLY on an invalid
    /// selector; a valid selector matching nothing is an honest `0`, never a refuse.
    public static func shapeCount(_ dict: [String: Any], selector: String, app: String)
        throws -> Int {
        guard WebActuate.boolValue(dict["ok"]) else {
            throw GhostHandsError.selectorNotFound(selector: selector, app: app)
        }
        return WebActuate.doubleValue(dict["count"]).map { Int($0) } ?? 0
    }
}

// MARK: - Live extract verbs (impure thin — pure shaping above)

extension GhostHands {
    /// A `web text` / `web attr` result handed to the CLI: the browser, the
    /// selector, the ordered values, whether `--all` was requested, and the port.
    public struct WebExtractResult: Sendable {
        public let app: String
        public let selector: String
        public let verb: String
        public let values: [String?]
        public let all: Bool
        public let port: Int
    }

    /// A `web count` result: the browser, selector, match count, and port.
    public struct WebCountResult: Sendable {
        public let app: String
        public let selector: String
        public let count: Int
        public let port: Int
    }

    /// `web text <css> [--all]` — the visible text of the matched element(s).
    @MainActor
    public static func webText(selector: String, all: Bool, browser: String,
                               lens: WebLens, debugPort: Int = 9222,
                               relaunch: Bool = false) async throws -> WebExtractResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        // A ref resolves to its data-attribute selector (CSS passes through).
        let resolved = WebRef.resolve(selector)
        let probe = try await evaluateObject(
            session, WebExtract.textProbeExpression(selector: resolved.selector))
        if resolved.isRef, !WebActuate.boolValue(probe["ok"]) {
            throw GhostHandsError.staleRef(ref: selector)
        }
        let extracted = try WebExtract.shapeText(probe, selector: selector, app: target.name)
        return WebExtractResult(app: target.name, selector: selector, verb: "text",
                                values: extracted.values, all: all, port: port)
    }

    /// `web attr <css> <name> [--all]` — an attribute of the matched element(s).
    @MainActor
    public static func webAttr(selector: String, name: String, all: Bool,
                               browser: String, lens: WebLens, debugPort: Int = 9222,
                               relaunch: Bool = false) async throws -> WebExtractResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        let resolved = WebRef.resolve(selector)
        let probe = try await evaluateObject(
            session, WebExtract.attrProbeExpression(selector: resolved.selector, name: name))
        if resolved.isRef, !WebActuate.boolValue(probe["ok"]) {
            throw GhostHandsError.staleRef(ref: selector)
        }
        let extracted = try WebExtract.shapeAttr(probe, selector: selector, app: target.name)
        return WebExtractResult(app: target.name, selector: selector,
                                verb: "attr \(name)", values: extracted.values,
                                all: all, port: port)
    }

    /// `web count <css>` — the number of elements the selector matches (0 honest).
    @MainActor
    public static func webCount(selector: String, browser: String, lens: WebLens,
                                debugPort: Int = 9222, relaunch: Bool = false)
        async throws -> WebCountResult {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        let resolved = WebRef.resolve(selector)
        let probe = try await evaluateObject(
            session, WebExtract.countProbeExpression(selector: resolved.selector))
        if resolved.isRef, !WebActuate.boolValue(probe["ok"]) {
            throw GhostHandsError.staleRef(ref: selector)
        }
        let count = try WebExtract.shapeCount(probe, selector: selector, app: target.name)
        return WebCountResult(app: target.name, selector: selector, count: count, port: port)
    }
}
