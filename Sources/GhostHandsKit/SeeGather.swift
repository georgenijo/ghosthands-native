import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation

// The IMPURE 3-eye gather for `see` — resolve the app, read each eye best-effort
// (AX always; CDP only when a debug port truly belongs to the target; OCR when
// Screen Recording is granted), normalize each into `SeeInput`, and hand the lot to
// the PURE `SeeFusion.fuse`. One eye failing NEVER blinds the others — `see` still
// returns what it could honestly read, and the footer says which eyes contributed.

extension GhostHands {
    /// AX roles `see` drops from the fused view — the menu bar + menu structures.
    /// They are the `menu` verb's surface (a separate access path), not the window's
    /// on-screen controls, and apps expose them as hundreds of zero-size nodes.
    static let seeExcludedRoles: Set<String> = [
        "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem",
    ]

    /// The result of one `see`: the fused rows + per-eye counts + the served CDP
    /// port + honest notes (why an eye contributed nothing).
    public struct SeeResult: Sendable {
        public let app: String
        public let rows: [SeeRow]
        public let axCount: Int
        public let cdpCount: Int
        public let ocrCount: Int
        /// The CDP port the cdp eye read (nil when CDP wasn't used).
        public let port: Int?
        /// Honest, human-readable reasons an eye contributed nothing (e.g. OCR
        /// needs Screen Recording; a `--target` matched no renderer). Surfaced to
        /// the footer — never hidden.
        public let notes: [String]

        public init(app: String, rows: [SeeRow], axCount: Int, cdpCount: Int,
                    ocrCount: Int, port: Int?, notes: [String]) {
            self.app = app
            self.rows = rows
            self.axCount = axCount
            self.cdpCount = cdpCount
            self.ocrCount = ocrCount
            self.port = port
            self.notes = notes
        }
    }

    /// `see <app> [--debug-port N] [--target n|title] [--no-ocr]` — ONE fused eye.
    /// Merges the AX tree + (when a debug port truly belongs to the target) the CDP
    /// DOM + (when Screen Recording is granted) Vision OCR into a single ranked,
    /// de-duplicated, `@ref`-stamped list, and PERSISTS the ref→record map so
    /// `act "@ref"` can re-actuate. Pure READ — never fabricates an element; an app
    /// the eyes see nothing in returns an honest empty list.
    @MainActor
    public static func see(appSpec: String, debugPort: Int? = nil,
                           pick: CDPTargetPick.Selector? = nil,
                           runOCR: Bool = true) async throws -> SeeResult {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)
        var notes: [String] = []

        // --- AX eye (the app's WINDOW tree) ---
        // Reuse the proven snapshot walk: `SnapshotWalker.forest` is windows-driven
        // (the menu bar / collapsed menus never enter — those are the `menu` verb's
        // surface), depth + visited bounded (cycle-safe), with the SAME cold-tree
        // settle+retry `snapshot` uses. The role filter is belt-and-suspenders for
        // any menu node that still slips in. (Note: a few macOS-26 apps expose a
        // degenerate 0×0 window whose AX subtree is sparse — `see` reports what AX
        // hands back honestly rather than fabricating controls.)
        var forest = SnapshotWalker.forest(of: target.element)
        if SnapshotRender.count(forest) == 0 {
            Thread.sleep(forTimeInterval: 0.4)
            forest = SnapshotWalker.forest(of: Element(AXUIElementCreateApplication(target.pid)))
        }
        var axInputs: [SeeInput] = []
        func collectAX(_ node: SnapshotNode) {
            let f = node.facts
            if !(f.role.map { Self.seeExcludedRoles.contains($0) } ?? false) {
                let interactive = Finder.isActionable(f)
                let name = SnapshotRender.displayName(f) ?? ""
                if interactive || !name.isEmpty {
                    axInputs.append(SeeInput(source: .ax, role: f.role ?? "?", name: name,
                                             rect: f.frame, interactive: interactive))
                }
            }
            for child in node.children { collectAX(child) }
        }
        for node in forest { collectAX(node) }

        // --- CDP eye (only when a port TRULY belongs to the target) ---
        // SAFE rule: an explicit --debug-port (the user asserts it is the target's
        // renderer port), OR the target is a browser-surface app with its standard
        // port open. NEVER probe 9222 for a random native app — that would pull an
        // UNRELATED browser's page into this app's view (a fabrication).
        var cdpInputs: [SeeInput] = []
        var usedPort: Int?
        var usedTargetId: String?
        var candidatePort = debugPort
        if candidatePort == nil,
           WebSurface.isBrowserSurface(bundleID: target.app.bundleIdentifier) {
            candidatePort = 9222
        }
        if let p = candidatePort, await CDPDiscovery.isPortOpen(p) {
            do {
                let result = try await webReadCDP(target: target, port: p, pick: pick)
                usedPort = p
                usedTargetId = result.cdpTargetId   // pin act's reattach to this renderer
                for e in result.entries {
                    let name = SnapshotRender.displayName(e.facts) ?? ""
                    cdpInputs.append(SeeInput(
                        source: .cdp, role: e.facts.role ?? "?", name: name,
                        rect: e.facts.frame, interactive: e.ref != nil, cdpRef: e.ref))
                }
            } catch let err as GhostHandsError {
                // A CDP failure (e.g. a --target no-match) must NOT blind AX/OCR —
                // skip the CDP eye and say why, honestly.
                notes.append("cdp: \(err)")
            } catch {
                notes.append("cdp: unreadable")
            }
        } else if debugPort != nil {
            notes.append("cdp: debug port \(debugPort!) not open")
        }

        // --- OCR eye (best-effort; needs Screen Recording) ---
        var ocrInputs: [SeeInput] = []
        if runOCR {
            do {
                for it in try await GhostHands.ocr(appSpec: appSpec) {
                    let text = it.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    ocrInputs.append(SeeInput(source: .ocr, role: "text", name: text,
                                              rect: it.screenRect, interactive: false))
                }
            } catch let err as GhostHandsError {
                notes.append("ocr: \(err)")
            } catch {
                notes.append("ocr: unavailable")
            }
        } else {
            notes.append("ocr: skipped (--no-ocr)")
        }

        // --- fuse (STABLE order ax → cdp → ocr so dedup is deterministic) ---
        let rows = SeeFusion.fuse(axInputs + cdpInputs + ocrInputs)

        // --- persist the ref→record map for `act "@ref"` ---
        let snap = SeeSnapshot(app: target.name, pid: target.pid, port: usedPort,
                               cdpTargetId: usedTargetId,
                               records: rows.map(SeeRecord.init(row:)))
        if !SeeStore.save(snap) {
            notes.append("warning: could not persist the see snapshot — `act @ref` "
                + "will refuse until the next see")
        }

        return SeeResult(app: target.name, rows: rows, axCount: axInputs.count,
                         cdpCount: cdpInputs.count, ocrCount: ocrInputs.count,
                         port: usedPort, notes: notes)
    }
}
