import CoreGraphics
import Foundation

// GhostHands SEE tier — ONE fused eye over a Mac app. The brain calls `see <app>`
// once and gets a single ranked, de-duplicated, @ref-stamped element list merged
// from the THREE eyes the brain used to juggle by hand:
//
//   AX  — the Accessibility tree (native controls, invisible, screen coords)
//   CDP — the live DOM of a browser/Electron renderer (when a debug port is
//         reachable; carries a precise @eN handle; page/viewport coords)
//   OCR — Apple Vision text + on-screen rects (the universal fallback eye for a
//         canvas/game/no-AX surface; screen coords)
//
// Each fused row carries: ref, role, name, on-screen rect, source (ax|cdp|ocr),
// and the best actuation tier for that source — everything `act "@ref"` (the A3
// actuator) needs to AUTO-PICK the hand. This file is the PURE heart: the fusion
// (dedup + rank + ref-assign), the persisted record shape, and the render — all
// over FABRICATED inputs, hermetically tested. The impure 3-eye gather lives in
// `SeeGather.swift`.
//
// HONESTY: `see` is a pure READ. It NEVER fabricates an element — every row comes
// from a real eye, and a row with no readable rect is marked `frame:?`, never a
// guessed box. An app the eyes see nothing in yields an honest empty list, never a
// fabricated one. Coordinate spaces differ across eyes (AX/OCR are screen, CDP is
// page), so cross-eye dedup leans on NAME, not just rect — documented below.

// MARK: - Which eye produced a row

public enum SeeSource: String, Sendable, Equatable, Codable {
    case ax, cdp, ocr
}

// MARK: - SeeInput: one element from a single eye, normalized for fusion

/// A normalized element from one eye, BEFORE fusion. The gather maps each eye's
/// native shape (`ElementFacts` / `WebDigest.Entry` / `OCRItem`) into this so the
/// fusion is pure and eye-agnostic.
public struct SeeInput: Sendable, Equatable {
    public var source: SeeSource
    /// The role/kind label as the eye reports it ("AXButton", "button", "text").
    public var role: String
    /// The accessible/visible name; "" when the eye exposes none.
    public var name: String
    /// The on-screen (AX/OCR) or page (CDP) rect; nil when the eye gave no box.
    public var rect: CGRect?
    /// True iff this element is actionable/clickable per its eye.
    public var interactive: Bool
    /// The CDP `@eN` handle (cdp source only) — the precise DOM actuation address.
    public var cdpRef: String?

    public init(source: SeeSource, role: String, name: String, rect: CGRect?,
                interactive: Bool, cdpRef: String? = nil) {
        self.source = source
        self.role = role
        self.name = name
        self.rect = rect
        self.interactive = interactive
        self.cdpRef = cdpRef
    }
}

// MARK: - SeeRow: one fused, ref-stamped row

/// A fused row in the unified view, addressable by `ref` (the `@N` handle `act`
/// resolves). Carries enough to display AND (via `SeeRecord`) to re-actuate.
public struct SeeRow: Sendable, Equatable {
    public var ref: String          // "@1", "@2", … assigned in ranked order
    public var source: SeeSource
    public var role: String
    public var name: String
    public var rect: CGRect?
    public var interactive: Bool
    public var cdpRef: String?

    public init(ref: String, source: SeeSource, role: String, name: String,
                rect: CGRect?, interactive: Bool, cdpRef: String? = nil) {
        self.ref = ref
        self.source = source
        self.role = role
        self.name = name
        self.rect = rect
        self.interactive = interactive
        self.cdpRef = cdpRef
    }

    /// The best actuation tier for this row's source — what `act "@ref"` will use:
    /// an `ax` element gets the invisible AX press (read-only when not actionable);
    /// a `cdp` element the precise CDP click/type; an `ocr`-only element the visible
    /// HID click (the fuzzy last resort). Honestly labels which hand will act.
    public var tier: String {
        switch source {
        case .ax:  return interactive ? "ax-press" : "ax-read"
        case .cdp: return "cdp"
        case .ocr: return "hid-click"
        }
    }
}

// MARK: - SeeFusion: the pure dedup + rank + ref-assign

public enum SeeFusion {
    /// Actuation priority when collapsing duplicates (higher wins). CDP gives a
    /// precise DOM ref + the proven web-actuation path, so it wins over the AX view
    /// of the same web element; AX (invisible native press) wins over OCR (the fuzzy
    /// visible fallback). So a web button seen by all three collapses to its CDP row.
    static func priority(_ s: SeeSource) -> Int {
        switch s {
        case .cdp: return 3
        case .ax:  return 2
        case .ocr: return 1
        }
    }

    /// Intersection-over-union of two rects, 0 when either is empty/degenerate.
    /// Only meaningful for two rects in the SAME coordinate space (AX↔OCR, or
    /// CDP↔CDP) — used as the rect arm of `sameElement`.
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return 0 }
        let ix = max(a.minX, b.minX), iy = max(a.minY, b.minY)
        let ax2 = min(a.maxX, b.maxX), ay2 = min(a.maxY, b.maxY)
        let iw = ax2 - ix, ih = ay2 - iy
        guard iw > 0, ih > 0 else { return 0 }
        let inter = Double(iw * ih)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    static func normName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// VISIBLE = a rect with positive area. A zero-area frame (`0×0`, common on
    /// collapsed/off-screen AX nodes like menu items) is NOT a thing a human can see
    /// or a hand can aim at, so it ranks BELOW real on-screen elements — never first.
    static func isVisible(_ rect: CGRect?) -> Bool {
        guard let r = rect else { return false }
        return r.width > 0 && r.height > 0
    }

    /// Do two inputs describe the SAME on-screen element? Conservative — collapses
    /// only on strong evidence so two distinct controls never merge:
    ///  - RECT arm: both rects present AND IoU ≥ 0.5 (same coord space — AX↔OCR,
    ///    CDP↔CDP). This catches the OCR line sitting on top of an AX control.
    ///  - NAME arm (the cross-coord-space bridge): a non-empty name that is EQUAL
    ///    (case-insensitive), both elements INTERACTIVE, and from DIFFERENT sources.
    ///    This collapses a CDP button and its AX shadow (whose rects live in
    ///    different coord spaces, so the rect arm can't see they're the same) while
    ///    refusing to merge two same-source "OK" buttons (same source ⇒ not merged).
    static func sameElement(_ a: SeeInput, _ b: SeeInput) -> Bool {
        if let ra = a.rect, let rb = b.rect, iou(ra, rb) >= 0.5 { return true }
        let na = normName(a.name)
        if !na.isEmpty, na == normName(b.name), a.interactive, b.interactive,
           a.source != b.source {
            return true
        }
        return false
    }

    /// Replace `kept` with `incoming` (keep the higher-priority source's row) when
    /// they collapse — but PRESERVE a CDP ref if only one side has it (so collapsing
    /// an AX row that lacks a ref onto a CDP row, or vice versa, never drops the
    /// precise handle). Returns the merged representative.
    static func merge(kept: SeeInput, incoming: SeeInput) -> SeeInput {
        var winner = priority(incoming.source) > priority(kept.source) ? incoming : kept
        // Never lose a CDP ref to the collapse.
        if winner.cdpRef == nil { winner.cdpRef = kept.cdpRef ?? incoming.cdpRef }
        return winner
    }

    /// Fuse the eyes' inputs into a single ranked, de-duplicated, @ref-stamped list.
    ///
    /// 1. DEDUP — greedy: walk inputs in the given order; collapse each into the
    ///    first kept cluster it matches (`sameElement`), keeping the higher-priority
    ///    source. Pass inputs in a STABLE order (the gather does ax→cdp→ocr) so the
    ///    result is deterministic.
    /// 2. RANK — interactive first, then named, then has-rect, then reading order
    ///    (top-to-bottom, left-to-right); ties broken by source priority then name
    ///    then role so the order is TOTAL (deterministic across sort runs).
    /// 3. REF — assign `@1…@N` in ranked order.
    public static func fuse(_ inputs: [SeeInput]) -> [SeeRow] {
        // Per-source interactive-name frequency. The cross-coord-space NAME bridge
        // only fires for a name that identifies EXACTLY ONE interactive element in
        // EACH source — so two distinct same-named controls (e.g. two "Edit" links on
        // a page) are NEVER collapsed into one (which would DROP a real element). A
        // duplicated name falls back to the rect arm only (same-space dupes), keeping
        // every distinct control.
        var nameCount: [SeeSource: [String: Int]] = [:]
        for inp in inputs where inp.interactive {
            let n = normName(inp.name)
            guard !n.isEmpty else { continue }
            nameCount[inp.source, default: [:]][n, default: 0] += 1
        }
        func uniquePerSource(_ inp: SeeInput) -> Bool {
            (nameCount[inp.source]?[normName(inp.name)] ?? 0) == 1
        }
        func matches(_ a: SeeInput, _ b: SeeInput) -> Bool {
            // Rect arm — same coord space, strong overlap.
            if let ra = a.rect, let rb = b.rect, iou(ra, rb) >= 0.5 { return true }
            // Name arm — cross-coord-space bridge, gated on per-source uniqueness.
            let na = normName(a.name)
            return !na.isEmpty && na == normName(b.name) && a.interactive && b.interactive
                && a.source != b.source && uniquePerSource(a) && uniquePerSource(b)
        }
        // 1. dedup
        var kept: [SeeInput] = []
        for x in inputs {
            if let i = kept.firstIndex(where: { matches($0, x) }) {
                kept[i] = merge(kept: kept[i], incoming: x)
            } else {
                kept.append(x)
            }
        }
        // 2. rank — a TOTAL order (every field compared, final tiebreaks guarantee
        // determinism since Swift's sort is not guaranteed stable).
        let ranked = kept.enumerated().sorted { lhsE, rhsE in
            let l = lhsE.element, r = rhsE.element
            let lVis = isVisible(l.rect), rVis = isVisible(r.rect)
            if lVis != rVis { return lVis }                                 // visible first
            // Among visible elements, interactive + named lead; a visible interactive
            // control is what a brain most wants to act on.
            if l.interactive != r.interactive { return l.interactive }      // interactive first
            let lNamed = !normName(l.name).isEmpty, rNamed = !normName(r.name).isEmpty
            if lNamed != rNamed { return lNamed }                            // named first
            if lVis, rVis, let lr = l.rect, let rr = r.rect {              // reading order
                if abs(lr.minY - rr.minY) > 1 { return lr.minY < rr.minY }
                if abs(lr.minX - rr.minX) > 1 { return lr.minX < rr.minX }
            }
            if l.source != r.source { return priority(l.source) > priority(r.source) }
            let ln = normName(l.name), rn = normName(r.name)
            if ln != rn { return ln < rn }
            if l.role != r.role { return l.role < r.role }
            return lhsE.offset < rhsE.offset                                // stable final
        }.map { $0.element }
        // 3. ref
        return ranked.enumerated().map { i, e in
            SeeRow(ref: "@\(i + 1)", source: e.source, role: e.role, name: e.name,
                   rect: e.rect, interactive: e.interactive, cdpRef: e.cdpRef)
        }
    }
}

// MARK: - Persistence: the ref→record store `act` reads

/// One persisted row — enough for `act "@ref"` to re-resolve + re-actuate the
/// element and to detect staleness. `rect` is `[x,y,w,h]` (or nil) for Codable.
public struct SeeRecord: Codable, Sendable, Equatable {
    public var ref: String
    public var source: SeeSource
    public var role: String
    public var name: String
    public var rect: [Double]?
    public var interactive: Bool
    public var cdpRef: String?
    /// The AX-IDENTITY pin for an `ax` row: this control's 0-based rank among the
    /// SAME-(role, name) actuation candidates, in the deterministic
    /// `Finder.candidateMatches` tree order that `act` re-resolves over. Stamped at
    /// see-time SO `act "@ref"` can re-find THIS control by identity on a fresh tree
    /// (role + name + nth) rather than collapsing the ref back to its name alone —
    /// which, with two distinct same-named controls, could refuse unnecessarily or
    /// act on the WRONG survivor. Nil for non-ax rows, or when see could not pin a
    /// stable index (then `act` falls back to name+role and still refuses on
    /// ambiguity — never guesses). See `ActRef.swift`.
    public var axIndex: Int?

    public init(ref: String, source: SeeSource, role: String, name: String,
                rect: [Double]?, interactive: Bool, cdpRef: String?,
                axIndex: Int? = nil) {
        self.ref = ref
        self.source = source
        self.role = role
        self.name = name
        self.rect = rect
        self.interactive = interactive
        self.cdpRef = cdpRef
        self.axIndex = axIndex
    }

    /// Build a record from a fused row (rect → `[x,y,w,h]`). `axIndex` is supplied
    /// separately by the see gather (it needs a live AX re-walk to pin), defaulting
    /// to nil for rows with no stable identity index.
    public init(row: SeeRow, axIndex: Int? = nil) {
        self.ref = row.ref
        self.source = row.source
        self.role = row.role
        self.name = row.name
        self.rect = row.rect.map { [$0.minX, $0.minY, $0.width, $0.height] }
        self.interactive = row.interactive
        self.cdpRef = row.cdpRef
        self.axIndex = axIndex
    }

    /// The stored AX identity as a reusable `LocatorSpec` — the SAME disambiguation
    /// the click/type verbs accept (`--role`/`--text`/`--nth`). `act` re-resolves
    /// THIS on a fresh tree instead of re-finding by name alone. Role always pins;
    /// `nth` pins the among-same-name rank when see could stamp it. With no stored
    /// index the spec still narrows by role and the verb refuses on a remaining
    /// ambiguity (never silently picks).
    public var axLocator: LocatorSpec {
        LocatorSpec(role: role, text: nil, nth: axIndex)
    }

    /// The CGRect this record's `[x,y,w,h]` describes, or nil.
    public var cgRect: CGRect? {
        guard let r = rect, r.count == 4 else { return nil }
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }
}

/// The persisted result of the LAST `see` — what `act "@ref"` loads. Keyed by app
/// so `act` can confirm the ref belongs to the app it's acting on, plus the CDP
/// port (when the see used the CDP eye) so `act` can reattach.
public struct SeeSnapshot: Codable, Sendable, Equatable {
    public var app: String
    /// The app's PID at see-time — A3's `act` compares it to the live PID so a ref
    /// from a since-relaunched app (same name, different process) REFUSES "re-see"
    /// rather than acting on a stale AX identity. Nil only for older snapshots.
    public var pid: Int32?
    public var port: Int?
    /// The stable DevTools target id of the CDP renderer `see` read (nil for an
    /// AX-only / native see). `act` pins CDP `@ref` reattach to this exact target so
    /// a ref stamped on a non-default page (multi-window Electron / `see --target N`)
    /// is found there, not falsely refused as stale on page 0.
    public var cdpTargetId: String?
    public var records: [SeeRecord]

    public init(app: String, pid: Int32? = nil, port: Int?,
                cdpTargetId: String? = nil, records: [SeeRecord]) {
        self.app = app
        self.pid = pid
        self.port = port
        self.cdpTargetId = cdpTargetId
        self.records = records
    }

    /// Resolve a `@ref` (e.g. "@3") to its record, or nil when absent (the caller
    /// REFUSES "re-see").
    public func record(for ref: String) -> SeeRecord? {
        records.first { $0.ref == ref }
    }
}

/// Reads/writes the last-see snapshot at `~/.ghosthands/see.json`. Mirrors
/// `WebSessionStore` (impure only at the filesystem; the Codable shape is pure).
public enum SeeStore {
    public static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghosthands", isDirectory: true)
            .appendingPathComponent("see.json", isDirectory: false)
    }

    public static func load() -> SeeSnapshot? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(SeeSnapshot.self, from: data)
    }

    /// Persist the snapshot, creating `~/.ghosthands` if needed. A write failure is
    /// non-fatal to `see` (the on-screen list still prints) — it only means a later
    /// `act "@ref"` can't resolve, which `act` reports honestly as "re-see".
    @discardableResult
    public static func save(_ snap: SeeSnapshot) -> Bool {
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(snap).write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: path)
    }
}

// MARK: - Render (pure)

public enum SeeRender {
    /// One row line: `@3  AXButton "Submit"  @(x,y w×h)  [ax] ax-press`. A rectless
    /// row prints `frame:?` (never a fabricated box). Reuses `WebDigest.frameString`
    /// so the geometry format matches the rest of the kit.
    public static func line(_ row: SeeRow) -> String {
        let name = row.name.isEmpty ? "" : " \(row.name.debugDescription)"
        let frame = row.rect.map { WebDigest.frameString($0) } ?? "frame:?"
        return "\(row.ref)  \(row.role)\(name)  \(frame)  [\(row.source.rawValue)] \(row.tier)"
    }

    public static func render(_ rows: [SeeRow]) -> String {
        rows.map(line).joined(separator: "\n")
    }
}
