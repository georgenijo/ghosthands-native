import Foundation

// GhostHands WEB FIND tier — the "see-the-words" backup addressing (issue #7's
// secondary path, shipped AFTER refs because refs cover ~90% of clicks).
//
// Refs (`@eN`) are the fast everyday path: look once, point by number. The backup
// is for when refs don't fit — no prior `web read`, or a page that keeps
// re-rendering. It addresses an element by WHAT A HUMAN SEES (its visible text /
// label), never a hidden code name:
//
//   web click --text "Sign in"            — click the control that says "Sign in"
//   web fill  --text "Email" "<value>"    — fill the field labeled "Email"
//   …--nth N                              — disambiguate a tie (1-based)
//
// DESIGN (locked in #7):
//   1. Resolve by visible text / label / role — re-resolved LIVE at action time,
//      so it can never go stale the way a number can.
//   2. On a tie, RANK (exact > prefix > contains; in-viewport; top-most) and act on
//      the obvious top one — don't refuse by default; report the count + accept
//      `--nth N` to choose another.
//   3. Stay honest — report WHICH element was picked, then verify the effect (the
//      same navigation / read-back proof as every actuation).
//
// PURITY: the resolver JS is built here (PURE string), and the reply is classified
// by a PURE `decide` over a FABRICATED `[String: Any]`. The actual evaluate +
// actuation are the impure half in `GhostHands.webClickByText` / `webFillByText`.

/// The pure find model: the per-mode resolver expression + the classification of
/// its reply into found / none / out-of-range.
public enum WebFind {
    /// The attribute the resolver stamps on the CHOSEN element, and the selector
    /// the actuation then acts on. Stamping the live pick (then acting on it by a
    /// stable selector) keeps the find honest: we act on the exact element we
    /// reported picking, through the same occlusion + verify path as every click.
    public static let pickSelector = "[data-gh-find=\"1\"]"

    /// The classification of a resolver reply.
    public enum Decision: Sendable, Equatable {
        /// A ranked pick was found + stamped — `count` total matched (>1 ⇒ a tie was
        /// broken by ranking; the caller reports it and offers `--nth`).
        case found(label: String, count: Int)
        /// No visible element matched the text — REFUSE (`elementNotFound`).
        case none(count: Int)
        /// `--nth N` pointed past the match list — REFUSE (`locatorIndexOutOfRange`).
        case outOfRange(count: Int)
    }

    /// Classify a resolver reply. Pure — unit-tested over fabricated dictionaries.
    public static func decide(_ dict: [String: Any]) -> Decision {
        let count = WebActuate.doubleValue(dict["count"]).map { Int($0) } ?? 0
        if WebActuate.boolValue(dict["outOfRange"]) { return .outOfRange(count: count) }
        guard WebActuate.boolValue(dict["found"]) else { return .none(count: count) }
        let label = (dict["label"] as? String) ?? ""
        return .found(label: label, count: count)
    }

    /// The accessible-label JS for a CLICK target — what a human reads ON the
    /// control (aria-label, then its visible text, then a value/title).
    static let clickLabelJS = """
    function labelOf(el) {
      return ((el.getAttribute('aria-label') || el.innerText || el.value
               || el.getAttribute('title') || '')).trim();
    }
    """

    /// The accessible-label JS for a FILL target — a field has no visible text of
    /// its own, so resolve its LABEL: aria-label, placeholder, an associated
    /// `<label for>` / wrapping `<label>`, then title / name.
    static let fillLabelJS = """
    function labelOf(el) {
      let t = el.getAttribute('aria-label') || el.getAttribute('placeholder') || '';
      if (!t && el.id) {
        try {
          // Resolve `label[for]` in the element's OWN root (document or shadow root)
          // so a field inside a web component still finds its label.
          const scope = (el.getRootNode && el.getRootNode()) || document;
          const l = scope.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (l) t = l.innerText;
        } catch (e) {}
      }
      if (!t && el.closest) { const p = el.closest('label'); if (p) t = p.innerText; }
      if (!t) t = el.getAttribute('title') || el.getAttribute('name') || '';
      return (t || '').trim();
    }
    """

    /// Build the resolver expression: find visible candidates whose label matches
    /// `text`, RANK them, pick `nth` (0-based; nil/-1 ⇒ the top-ranked one), stamp
    /// the pick, and report `{ found, count, label }` (or `{ found:false }` /
    /// `{ outOfRange:true }`). `fillable` switches the candidate set + label rule.
    public static func resolveExpression(text: String, nth: Int?, fillable: Bool) -> String {
        let needle = WebActuate.jsonStringLiteral(text)
        let nthLit = nth.map(String.init) ?? "-1"
        let candidates = fillable
            ? "input,textarea,select,[contenteditable=''],[contenteditable=\\\"true\\\"]"
            : "a,button,input,select,textarea,summary,[role=button],[role=link],"
                + "[role=tab],[role=checkbox],[role=menuitem],[onclick]"
        let labelFn = fillable ? fillLabelJS : clickLabelJS
        return """
        (() => {
          \(CDPDigest.shadowPierceJS)
          const want = \(needle).toLowerCase();
          const nth = \(nthLit);
          \(labelFn)
          const cands = [];
          // Gather candidates across the document AND every open shadow root /
          // same-origin iframe, so a control inside a web component (e.g. Cursor's
          // composer) is addressable by its visible text, not just top-level DOM.
          ghForEachRoot((root) => {
            let els;
            try { els = root.querySelectorAll("\(candidates)"); } catch (e) { els = []; }
            for (const el of els) {
              const label = labelOf(el);
              if (!label) continue;
              const ll = label.toLowerCase();
              const score = (ll === want) ? 3 : ll.startsWith(want) ? 2 : ll.includes(want) ? 1 : 0;
              if (!score) continue;
              const r = el.getBoundingClientRect();
              if (r.width <= 0 || r.height <= 0) continue;   // not visibly laid out
              // Translate a same-origin-iframe candidate's frame-local rect to
              // TOP-LEVEL coords (offset {0,0} for a plain element) so the viewport
              // test and the top-most (y then x) ranking compare apples to apples —
              // an iframe control at frame-local (10,10) must not out-rank a
              // top-level control just because its local y is small.
              const off = ghFrameOffset(el);
              const top = r.top + off.y, left = r.left + off.x;
              const bottom = r.bottom + off.y, right = r.right + off.x;
              const inVp = (top >= 0 && left >= 0
                            && bottom <= innerHeight && right <= innerWidth) ? 1 : 0;
              cands.push({ el, label, score, inVp, y: top, x: left });
            }
          });
          // Rank: exact > prefix > contains; in-viewport; top-most (y then x).
          cands.sort((a, b) => b.score - a.score || (b.inVp - a.inVp) || a.y - b.y || a.x - b.x);
          if (!cands.length) return { found: false, count: 0 };
          if (nth >= 0 && nth >= cands.length) return { found: false, outOfRange: true, count: cands.length };
          const pick = cands[nth >= 0 ? nth : 0];
          // Clear prior `data-gh-find` stamps across ALL roots, then stamp the pick.
          ghForEachRoot((root) => {
            let stamped;
            try { stamped = root.querySelectorAll('[data-gh-find]'); } catch (e) { stamped = []; }
            for (const e of stamped) e.removeAttribute('data-gh-find');
          });
          pick.el.setAttribute('data-gh-find', '1');
          return { found: true, count: cands.length, label: pick.label };
        })()
        """
    }
}
