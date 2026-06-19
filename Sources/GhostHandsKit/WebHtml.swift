import Foundation

// GhostHands WEB HTML / EVAL tier (CDP Slice 3) — two CDP-only READ verbs that
// look DEEPER into a page than the digest can:
//
//   web html <selector> <browser>  — for the FIRST element a CSS selector
//                                     resolves to, report exactly what the DOM
//                                     exposes: its tag, its outerHTML (sliced to
//                                     a sane cap), every attribute name→value,
//                                     and a CURATED set of computed-style props.
//   web eval  <js> <browser>        — Runtime.evaluate an arbitrary JS expression
//                                     (returnByValue, awaitPromise) and print the
//                                     value it returns. A power tool.
//
// HONESTY CONTRACT (same as the rest of the kit): both report ONLY what the page
// actually exposed. `web html` never fabricates an attribute or a style; a missing
// selector REFUSES (`selectorNotFound`) rather than printing an empty shell. `web
// eval` surfaces a page-side THROW as a transport refuse (`cdpTransport`) rather
// than flattening an exception into a fake empty success.
//
// PURITY: the only impure step is the one `Runtime.evaluate` per verb (in
// `GhostHands.webHtmlCDP` / `webEvalCDP`). Everything here — shaping the html
// result object into the sectioned rendered output, and classifying / stringifying
// the eval reply (incl. the exceptionDetails → throw mapping) — is a PURE function
// over a FABRICATED `[String: Any]`, so it is hermetically unit-tested with no
// socket and no browser.

// MARK: - web html: pure result shaping

/// The pure shaping of a `web html` probe result. The probe (built by
/// `htmlProbeExpression`) returns, for `document.querySelector(selector)`, a JSON
/// object `{ found, tag, outerHTML, attrs, computed }`; everything below renders
/// that object into clearly-sectioned text WITHOUT touching the DOM or a socket.
public enum WebHtml {
    /// outerHTML cap: a sane upper bound so a huge node (a whole `<body>`) doesn't
    /// flood the terminal. Sliced IN-PAGE (the probe) so we never ship megabytes
    /// over the socket; the shaper trusts the probe already capped, and the cap is
    /// surfaced honestly as a "(truncated…)" note when the slice hit the limit.
    public static let outerHTMLCap = 20_000

    /// The CURATED computed-style props `web html` reports — the handful that
    /// answer "why can't I see / click this?" (layout + visibility + the obvious
    /// paint props), in a STABLE display order. Honest by omission: we report this
    /// fixed subset, never the full ~350-prop CSSOM dump (noise), and never invent
    /// a prop the page didn't return.
    public static let computedProps: [String] = [
        "display", "visibility", "position",
        "color", "backgroundColor",
        "fontSize", "width", "height",
    ]

    /// The page probe expression for `web html <selector>`. For the FIRST match of
    /// `selector`, collect its tag, outerHTML (capped in-page), every attribute as
    /// a name→value map, and the curated computed-style subset. A miss returns
    /// `{ found: false }` and nothing else — the pure shaper maps that to a refuse.
    ///
    /// The selector is embedded as a JSON string literal so a quote/backslash in it
    /// can never break out of the expression (it is data, never code).
    public static func htmlProbeExpression(selector: String) -> String {
        let selJSON = WebActuate.jsonStringLiteral(selector)
        // The computed-prop list is embedded as a JSON array literal so the in-page
        // loop reads the SAME curated set the Swift renderer expects.
        let propsJSON = computedPropsJSONArray()
        return """
        (() => {
          \(CDPDigest.shadowPierceJS)
          const sel = \(selJSON);
          // Pierce open shadow roots / same-origin iframes so a `[data-gh-ref]`
          // stamped inside a web component is re-found (else a shadow @ref would
          // falsely refuse as stale). `ghQuery` swallows a bad-selector throw → null.
          const el = ghQuery(sel);
          if (!el) { return { found: false }; }
          const cap = \(outerHTMLCap);
          const raw = el.outerHTML || '';
          const outerHTML = raw.length > cap ? raw.slice(0, cap) : raw;
          const truncated = raw.length > cap;
          const attrs = {};
          if (el.attributes) {
            for (const a of el.attributes) { attrs[a.name] = a.value; }
          }
          const cs = window.getComputedStyle(el);
          const computed = {};
          for (const p of \(propsJSON)) { computed[p] = cs ? cs[p] : ''; }
          return {
            found: true,
            tag: (el.tagName || '').toLowerCase(),
            outerHTML, truncated, attrs, computed
          };
        })()
        """
    }

    /// The curated computed-prop list as a JS array literal, e.g.
    /// `["display","visibility",…]`, for embedding in the probe expression.
    static func computedPropsJSONArray() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: computedProps),
              let s = String(data: data, encoding: .utf8) else {
            // Should never happen for a fixed string array; fall back to an empty
            // array literal rather than emit malformed JS.
            return "[]"
        }
        return s
    }

    // MARK: Pure shaping

    /// The shaped, sectioned `web html` result: the resolved tag, the (already
    /// capped) outerHTML and whether it was truncated, the attribute pairs in a
    /// stable order, and the curated computed-style pairs in `computedProps` order.
    /// A pure value so the renderer is unit-tested over fabricated probe data.
    public struct Shaped: Sendable, Equatable {
        public var tag: String
        public var outerHTML: String
        public var truncated: Bool
        /// Attribute name→value pairs, sorted by name for a STABLE render (a JSON
        /// object has no inherent order, so we impose one rather than render a
        /// nondeterministic dump).
        public var attributes: [(name: String, value: String)]
        /// Curated computed-style pairs, in `computedProps` order (NOT sorted) — a
        /// prop the page didn't return is reported as "(not reported)" so the fixed
        /// subset always renders fully and honestly.
        public var computed: [(name: String, value: String)]

        public init(tag: String, outerHTML: String, truncated: Bool,
                    attributes: [(name: String, value: String)],
                    computed: [(name: String, value: String)]) {
            self.tag = tag
            self.outerHTML = outerHTML
            self.truncated = truncated
            self.attributes = attributes
            self.computed = computed
        }

        public static func == (lhs: Shaped, rhs: Shaped) -> Bool {
            lhs.tag == rhs.tag && lhs.outerHTML == rhs.outerHTML
                && lhs.truncated == rhs.truncated
                && lhs.attributes.elementsEqual(rhs.attributes, by: ==)
                && lhs.computed.elementsEqual(rhs.computed, by: ==)
        }
    }

    /// Marker for a curated computed prop the page did NOT return — honest by
    /// construction: we keep the prop visible (so the fixed subset always renders)
    /// but flag that the DOM exposed no value, never a fabricated one.
    public static let notReported = "(not reported)"

    /// THE pure shaper: turn a `web html` probe object into a `Shaped` value, or
    /// throw `selectorNotFound` when `found` is false. HONEST — every field is read
    /// straight from the probe; a missing attribute map shapes to `[]`, a missing
    /// computed value to `notReported`, never an invented value.
    ///
    /// `selector` / `app` are passed only to build the `selectorNotFound` refuse;
    /// the shaping itself depends solely on `dict`.
    public static func shape(_ dict: [String: Any], selector: String, app: String)
        throws -> Shaped {
        guard WebActuate.boolValue(dict["found"]) else {
            throw GhostHandsError.selectorNotFound(selector: selector, app: app)
        }
        let tag = (dict["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(unknown)"
        let outerHTML = (dict["outerHTML"] as? String) ?? ""
        let truncated = WebActuate.boolValue(dict["truncated"])
        let attributes = attributePairs(dict["attrs"])
        let computed = computedPairs(dict["computed"])
        return Shaped(tag: tag, outerHTML: outerHTML, truncated: truncated,
                      attributes: attributes, computed: computed)
    }

    /// Extract the attribute map into name-sorted `(name, value)` pairs. A non-map
    /// (or absent) `attrs` yields `[]` (honest "no attributes"), never a fabricated
    /// entry. Non-string values are stringified tolerantly.
    static func attributePairs(_ any: Any?) -> [(name: String, value: String)] {
        guard let map = any as? [String: Any] else { return [] }
        return map.keys.sorted().map { key in
            (name: key, value: stringifyAttr(map[key]))
        }
    }

    /// Extract the curated computed-style props in `computedProps` order. A prop the
    /// page omitted (or returned a non-string for) is reported as `notReported`, so
    /// the fixed subset ALWAYS renders fully — never silently shortened, never
    /// fabricated.
    static func computedPairs(_ any: Any?) -> [(name: String, value: String)] {
        let map = any as? [String: Any] ?? [:]
        return computedProps.map { prop in
            if let value = map[prop] as? String, !value.isEmpty {
                return (name: prop, value: value)
            }
            return (name: prop, value: notReported)
        }
    }

    /// Stringify an attribute value tolerantly: a String passes through; a number /
    /// bool is described; anything else falls back to an empty string (an empty-value
    /// attribute, e.g. `disabled`, is legitimately `""`).
    static func stringifyAttr(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: Render

    /// Render the shaped result into clearly-sectioned text: the outerHTML first
    /// (with a truncation note when capped), then the attributes, then the curated
    /// computed subset. The header names the tag so the reader knows WHAT resolved.
    public static func render(_ s: Shaped) -> String {
        var lines: [String] = []
        lines.append("<\(s.tag)>")

        lines.append("")
        lines.append("── outerHTML ──")
        lines.append(s.outerHTML)
        if s.truncated {
            lines.append("… (truncated to \(outerHTMLCap) chars)")
        }

        lines.append("")
        lines.append("── attributes ──")
        if s.attributes.isEmpty {
            lines.append("(none)")
        } else {
            for pair in s.attributes {
                lines.append("  \(pair.name) = \(pair.value.debugDescription)")
            }
        }

        lines.append("")
        lines.append("── computed ──")
        for pair in s.computed {
            lines.append("  \(pair.name): \(pair.value)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - web eval: pure value classification + stringify

/// The pure heart of `web eval`: classify a `Runtime.evaluate` reply into either a
/// page-side THROW (→ a `cdpTransport` refuse, surfacing the exception text) or a
/// returned VALUE (stringified for printing). No socket, no browser — fed a
/// FABRICATED reply dictionary, exactly the shape `CDPSession.call` returns.
public enum WebEval {
    /// The classification of a `Runtime.evaluate` reply.
    public enum Outcome: Sendable, Equatable {
        /// The page returned a value — already stringified for printing. An
        /// `undefined` / null result stringifies to a visible token (never a blank
        /// line that reads like a missing result).
        case value(String)
        /// The in-page expression THREW — carry the exception text so the caller
        /// raises `cdpTransport(reason:)` with it. NEVER a fake empty success.
        case threw(message: String)
    }

    /// THE pure classifier: inspect a `Runtime.evaluate` reply.
    ///
    ///  - `exceptionDetails` present → `.threw` with the best available message
    ///    (the thrown Error's `description`, else the top-level `text`, else a
    ///    generic note) — mirrors `GhostHands.throwIfEvaluateException`.
    ///  - else → `.value` with the `result` object stringified (see `stringify`).
    ///
    /// HONEST: a thrown page is a refuse signal, never flattened into an empty
    /// value; a genuinely undefined/null result is stringified to a visible token,
    /// never mistaken for a throw.
    public static func classify(_ reply: [String: Any]) -> Outcome {
        if let details = reply["exceptionDetails"] as? [String: Any] {
            return .threw(message: exceptionMessage(details))
        }
        let result = reply["result"] as? [String: Any] ?? [:]
        return .value(stringify(result))
    }

    /// The exception text from an `exceptionDetails` object — the thrown Error's
    /// `exception.description`, else the top-level `text` ("Uncaught …"), else a
    /// generic note. Identical precedence to `throwIfEvaluateException` so the two
    /// paths surface the same message.
    public static func exceptionMessage(_ details: [String: Any]) -> String {
        let exception = details["exception"] as? [String: Any]
        return (exception?["description"] as? String)
            ?? (details["text"] as? String)
            ?? "page-side JS exception"
    }

    /// Stringify the `result` object of a non-throwing `Runtime.evaluate` reply for
    /// printing. CDP's `result` is a `RemoteObject`:
    ///
    ///  - with `returnByValue`, a JSON-serializable value lands under `value` —
    ///    we render it (a string verbatim; an object/array re-encoded as compact
    ///    JSON; a number/bool described).
    ///  - `undefined` carries NO `value` key but `type: "undefined"` → the token
    ///    `undefined` (honest, distinct from an empty string).
    ///  - a `null` value decodes to `NSNull` → the token `null`.
    ///  - a non-serializable object (a DOM node, a function) reports its
    ///    `description` / `className` when present, else its `type`.
    ///
    /// Never returns a blank line for a real result: the reader always sees SOME
    /// honest token for what the page returned.
    public static func stringify(_ result: [String: Any]) -> String {
        // An explicit JS `undefined` has no `value` key.
        if result["value"] == nil {
            if let description = result["description"] as? String { return description }
            if let className = result["className"] as? String { return className }
            if let type = result["type"] as? String { return type }
            return "undefined"
        }
        return stringifyValue(result["value"])
    }

    /// Stringify a decoded JSON `value` from a `returnByValue` result. A String is
    /// returned verbatim (the common case — text the page produced); a bool/number
    /// is described; `NSNull` is `null`; an array/dictionary is re-encoded to
    /// compact JSON (sorted keys for a STABLE render); anything else falls back to
    /// its default description.
    static func stringifyValue(_ any: Any?) -> String {
        switch any {
        case let s as String:
            return s
        case is NSNull:
            return "null"
        case let n as NSNumber:
            // Bool decodes to an NSNumber too; render JS-style true/false for it.
            if isBool(n) { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let arr as [Any]:
            return jsonString(arr) ?? "\(arr)"
        case let dict as [String: Any]:
            return jsonString(dict) ?? "\(dict)"
        case .none:
            return "undefined"
        case let other?:
            return "\(other)"
        }
    }

    /// True iff an `NSNumber` actually wraps a JS boolean (so `true` doesn't render
    /// as `1`). `JSONSerialization` decodes JS booleans to the tagged CFBoolean,
    /// whose objCType is `c` (char) AND identity-matches kCFBooleanTrue/False.
    static func isBool(_ n: NSNumber) -> Bool {
        n === (true as NSNumber) || n === (false as NSNumber)
    }

    /// Compact JSON for an array/object value, sorted-keys for a stable render, or
    /// nil when it isn't serializable (the caller falls back to a plain description).
    static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
