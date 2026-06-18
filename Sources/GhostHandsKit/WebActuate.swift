import CoreGraphics
import Foundation

// GhostHands WEB ACTUATE tier — hands for browser surfaces, CDP only, no model.
//
// Two DOM-selector verbs that the AX tier CANNOT express (a CSS selector has no
// AX equivalent), so they REQUIRE CDP:
//
//   web click <selector> <browser>  — dispatch a TRUSTED click on the element a
//                                      CSS selector resolves to, after an
//                                      occlusion guard, verified by navigation.
//   web fill  <selector> <text>     — focus + set an input's value, verified by
//                                      reading the value back.
//
// HONESTY CONTRACT (same as the rest of the kit): an actuation is reported as
//   - VERIFIED              — an observed world-change proves it (navigation for
//                             click; a value read-back for fill).
//   - DISPATCHED-UNVERIFIED — the event was dispatched but no proof was observed
//                             (a click that didn't navigate; a field that didn't
//                             take the value). NEVER a success claim.
//   - REFUSE (throw)        — the selector is missing, the target is occluded, or
//                             a fill targets a secure field whose value can't be
//                             read back. We refuse rather than actuate blindly.
//
// PURITY: the AX/CDP-touching step is the single `Runtime.evaluate` probe + the
// `Input.dispatchMouseEvent` dispatch in `GhostHands.webClickCDP`/`webFillCDP`.
// Everything below — the click decision (found / covered / proceed + the center
// math), the click verdict (href-changed → verified), and the fill verdict
// (readback == text → verified) — is a PURE function over the FABRICATED probe
// dictionary, so it is hermetically unit-tested with no socket and no browser.

// MARK: - Pure: shared @ref addressing (read → click/fill use one handle)

/// The shared numbered-handle addressing that lets `web read` and `web
/// click`/`web fill` speak the SAME language (issue #7). `web read` stamps a
/// `data-gh-ref="eN"` attribute on each interactive element and prints `@eN`;
/// `web click @eN` / `web fill @eN` resolve that handle back to the element via
/// the attribute selector. CSS selectors keep working unchanged — refs are
/// ADDITIVE, recognised only by the `@e<digits>` shape, so a real selector like
/// `#submit` or `input[name=q]` passes straight through.
///
/// PURE string logic — no IO. The staleness check is NOT here: it lives at action
/// time (a ref whose `data-gh-ref` is gone after a nav/re-render matches nothing,
/// and the caller turns that miss into a `staleRef` refuse rather than acting).
public enum WebRef {
    /// Parse a ref handle `@e<digits>` (e.g. `@e5`) into its bare id (`e5`), or nil
    /// when the string is not a ref handle (so it is treated as a raw CSS selector).
    /// `@e` with no digits, `@elogin`, `#submit`, `input[name=q]` → nil (passthrough).
    public static func parse(_ s: String) -> String? {
        guard s.hasPrefix("@e") else { return nil }
        let id = s.dropFirst()              // "e5"
        let digits = id.dropFirst()         // "5"
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(id)
    }

    /// True iff `s` is a ref handle (vs a raw CSS selector).
    public static func isRef(_ s: String) -> Bool { parse(s) != nil }

    /// The CSS selector a ref id resolves to — the `data-gh-ref` attribute the read
    /// stamped. A gone attribute (nav/re-render) makes this match nothing → stale.
    public static func selector(forID id: String) -> String {
        "[data-gh-ref=\"\(id)\"]"
    }

    /// Resolve a click/fill/html target: a ref handle → (attribute selector,
    /// isRef:true); any other string is a raw CSS selector passed through verbatim
    /// (isRef:false). The caller probes with `.selector` and, on a no-match,
    /// REFUSES with `staleRef` when `.isRef` (the ref's element moved) vs
    /// `selectorNotFound` for a raw selector (a wrong/absent selector).
    public static func resolve(_ target: String) -> (selector: String, isRef: Bool) {
        if let id = parse(target) { return (selector(forID: id), true) }
        return (target, false)
    }
}

// MARK: - Pure: the occlusion + probe decision

/// The decision a `web click` makes from the page probe ALONE — the testable
/// heart. Either the selector missed, the target is occluded (refuse), or we
/// proceed to dispatch at a concrete center point inside a concrete box.
public enum ClickDecision: Sendable, Equatable {
    /// The selector matched no element — REFUSE (`selectorNotFound`).
    case notFound
    /// `document.elementFromPoint(center)` is NOT the target (nor an
    /// ancestor/descendant) — another element overlays it. REFUSE
    /// (`elementCovered`), carrying the covering element's tag name.
    case covered(by: String)
    /// The target is present and unoccluded — dispatch a click at `center`
    /// (the box's midpoint), within `box`.
    case proceed(center: CGPoint, box: CGRect)
}

/// The pure deciders + verdicts for the two selector verbs. All take a
/// FABRICATED `[String: Any]` (the `Runtime.evaluate` `returnByValue` object) and
/// return a value — no IO, mirroring `NavVerdict.decide` / `CDPDigest.entries`.
public enum WebActuate {
    /// The page probe expression: given a CSS `selector`, return a single JSON
    /// object describing the FIRST match for the occlusion guard + the dispatch
    /// geometry. `covered` is computed in-page off `document.elementFromPoint` so
    /// the overlay check sees the real paint order (a pure JS test we can't do
    /// off a static box). `isSecure` flags a password input so `fill` can refuse.
    ///
    ///   { found, covered, coveredBy, x, y, w, h, tag, type, isSecure }
    ///
    /// `x/y/w/h` are the bounding box in CSS px (page-relative — the same frame
    /// `Input.dispatchMouseEvent` expects, since it takes viewport coordinates and
    /// we read the box AFTER any scroll the caller already did). A missing element
    /// yields `{ found: false }` and nothing else.
    public static func probeExpression(selector: String) -> String {
        // The selector is embedded as a JSON string literal so a quote/backslash in
        // it can't break out of the expression (it is never trusted as code).
        let selJSON = jsonStringLiteral(selector)
        return """
        (() => {
          const sel = \(selJSON);
          let el;
          try { el = document.querySelector(sel); } catch (e) { el = null; }
          if (!el) { return { found: false }; }
          const r = el.getBoundingClientRect();
          const cx = r.x + r.width / 2;
          const cy = r.y + r.height / 2;
          const hit = document.elementFromPoint(cx, cy);
          // Covered iff the topmost element at the center is neither the target
          // nor inside it (a child painting on top is still the target) nor an
          // ancestor that wraps it (clicking the wrapper still hits the target).
          let covered = false;
          let coveredBy = '';
          if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) {
            covered = true;
            coveredBy = (hit.tagName || '').toLowerCase();
          }
          const tag = (el.tagName || '').toLowerCase();
          const type = (el.getAttribute && (el.getAttribute('type') || '')).toLowerCase();
          return {
            found: true, covered, coveredBy,
            x: r.x, y: r.y, w: r.width, h: r.height,
            tag, type, isSecure: (tag === 'input' && type === 'password')
          };
        })()
        """
    }

    /// THE pure decider: classify the probe object into notFound / covered /
    /// proceed, computing the dispatch center as the box midpoint. A `found` but
    /// `covered` object is the REFUSE; a `found`, un-covered object yields the
    /// concrete `center` + `box` to dispatch at.
    ///
    /// HONEST about geometry: a `found` object with no usable box (missing or
    /// zero-area `w/h`) is treated as `notFound` rather than dispatched at (0,0) —
    /// we never click a fabricated point.
    public static func clickDecision(from dict: [String: Any]) -> ClickDecision {
        guard boolValue(dict["found"]) else { return .notFound }
        if boolValue(dict["covered"]) {
            let by = (dict["coveredBy"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "element"
            return .covered(by: by)
        }
        guard let x = doubleValue(dict["x"]),
              let y = doubleValue(dict["y"]),
              let w = doubleValue(dict["w"]),
              let h = doubleValue(dict["h"]),
              w > 0, h > 0
        else { return .notFound }
        let box = CGRect(x: x, y: y, width: w, height: h)
        let center = CGPoint(x: x + w / 2, y: y + h / 2)
        return .proceed(center: center, box: box)
    }

    /// True iff the probe object reports a SECURE (password) input — the gate
    /// `web fill` uses to REFUSE (`secureFieldUnverifiable`): a password field's
    /// value can't be honestly read back, so a set can never be verified.
    public static func isSecure(from dict: [String: Any]) -> Bool {
        boolValue(dict["isSecure"])
    }

    // MARK: - Pure verdicts (mirror NavVerdict / ValueVerdict)

    /// One actuation verdict — VERIFIED (an observed world-change proved it) or
    /// DISPATCHED-UNVERIFIED (acted, effect unproven). NEVER a refuse: a refuse
    /// throws upstream and never reaches a verdict.
    public enum Verdict: Sendable, Equatable {
        case verified(evidence: String)
        case dispatchedUnverified(reason: String)
    }

    /// The CLICK verdict from the before/after page URLs ALONE. A navigation (the
    /// href changed) is the observable world-change that VERIFIES a click; a click
    /// that left the URL unchanged is honestly DISPATCHED-UNVERIFIED — the click
    /// landed, but its effect (an in-page handler, a no-op, an SPA route we can't
    /// read) is unproven. "the event dispatched" is NOT proof.
    public static func clickVerdict(hrefBefore: String?, hrefAfter: String?) -> Verdict {
        // A readable before AND after that DIFFER proves a navigation.
        if let before = hrefBefore, let after = hrefAfter, before != after {
            return .verified(evidence: "navigated \(before.debugDescription) → "
                + "\(after.debugDescription)")
        }
        let after = hrefAfter ?? hrefBefore
        let where_ = after.map { " (still \($0.debugDescription))" } ?? ""
        return .dispatchedUnverified(
            reason: "click dispatched; URL unchanged\(where_) — effect unverified")
    }

    /// The FILL verdict from the intended text vs the value READ BACK off the
    /// field ALONE. A read-back equal to the intended text VERIFIES the set; any
    /// other read-back (a field that rejected / transformed / capped the value, or
    /// one whose value couldn't be read) is honestly DISPATCHED-UNVERIFIED, NEVER
    /// a success claim.
    public static func fillVerdict(intended: String, readback: String?) -> Verdict {
        guard let readback else {
            return .dispatchedUnverified(
                reason: "set dispatched; field value could not be read back "
                    + "— effect unverified")
        }
        if readback == intended {
            return .verified(evidence: "field value reads back \(readback.debugDescription)")
        }
        return .dispatchedUnverified(
            reason: "set dispatched; field value reads back \(readback.debugDescription) "
                + "(≠ intended \(intended.debugDescription)) — effect unverified")
    }

    // MARK: - Small pure helpers (tolerant JSON coercion)

    /// Coerce a CDP `returnByValue` boolean (JS `true`/`false` decodes to an
    /// `NSNumber`) — tolerant of an `NSNumber`, a `Bool`, or a missing key (false).
    static func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return false
    }

    /// Coerce a CDP `returnByValue` boolean that may be ABSENT or JS `null` into a
    /// `Bool?` — distinguishing "no such state" (nil: missing key or `NSNull`) from
    /// an actual `false`. Used by `web read`'s form-state surfacing (#8) so a
    /// checkbox reports `checked=false` while a non-checkable control reports nothing.
    static func optBool(_ any: Any?) -> Bool? {
        guard let any, !(any is NSNull) else { return nil }
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }

    /// Coerce a CDP `returnByValue` number into a `Double`, or nil when absent /
    /// non-numeric — so a missing geometry field is honest "no box", never 0.
    static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    /// Encode a Swift string as a JSON string literal (with surrounding quotes) for
    /// safe embedding into a JS expression. Falls back to an empty-string literal
    /// only if encoding somehow fails (never an unescaped paste).
    static func jsonStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let arr = String(data: data, encoding: .utf8),
              arr.hasPrefix("["), arr.hasSuffix("]")
        else { return "\"\"" }
        // ["..."] → "..."  (strip the array brackets JSONSerialization requires).
        return String(arr.dropFirst().dropLast())
    }
}
