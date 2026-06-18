import ApplicationServices
import AXorcist
import Foundation

/// Shared AX read-back + effect-witness machinery for every mutating verb
/// (click / type / set-value / doubleclick / act). It captures the BEFORE
/// witness set scoped to a control's enclosing window, and — after the action —
/// re-reads the SAME window (pinned by CGWindowID, never a positional fallback)
/// twice, keeps only the witnesses that SETTLED, and diffs them. The pure
/// verdict logic stays in `ClickVerdict`/`ValueVerdict`/`DirectionVerdict`; this
/// is the (unavoidably AX-touching) plumbing that feeds them honest facts.
///
/// Extracting it here keeps the witness-scoping rules (window-pinning, the
/// settle-twice causation fence, the demote-on-2+ guard) in ONE audited place,
/// so `type`/`set-value`/`doubleclick`/`act` cannot accidentally diverge from
/// the click path's hard-won false-positive defences.
@MainActor
struct EffectProbe {
    let pid: pid_t
    let settle: TimeInterval
    private let resolver = AXWindowResolver()

    /// The witnesses scoped to `element`'s enclosing window, plus the pinned
    /// window id so the AFTER walk re-reads the SAME window. Capture this BEFORE
    /// dispatching the action.
    struct Before {
        let windowID: CGWindowID?
        let witnesses: [WitnessMatch.Witness]
    }

    func captureBefore(of element: Element) -> Before {
        let window = Finder.enclosingWindow(of: element)
        let id = window.flatMap { resolver.windowID(from: $0) }
        let witnesses = window.map { Finder.witnesses(in: $0) } ?? []
        return Before(windowID: id, witnesses: witnesses)
    }

    /// Re-read the BEFORE-window off `readbackRoot`, settle-twice for stability,
    /// and diff against the captured BEFORE set. Returns `.none` when we cannot
    /// re-pin the window or there were no witnesses (self-only verification — the
    /// honest under-claim). `readbackRoot` is the fresh tree the caller already
    /// read the control back from, reused so we don't re-walk the whole app.
    func diff(_ before: Before, readbackRoot: Element) -> WitnessMatch.Verdict {
        guard let windowID = before.windowID, !before.witnesses.isEmpty,
              let freshWindow = readbackRoot.windows()?
                  .first(where: { resolver.windowID(from: $0) == windowID }) else {
            return .none
        }
        let after1 = Finder.witnesses(in: freshWindow)
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        let secondWindow = Element(AXUIElementCreateApplication(pid)).windows()?
            .first(where: { resolver.windowID(from: $0) == windowID })
        let after2 = secondWindow.map { Finder.witnesses(in: $0) } ?? after1
        let settledAfter = WitnessMatch.stable(after1, after2)
        return WitnessMatch.diff(before: before.witnesses, after: settledAfter)
    }

    /// A FRESH application root — never the stale handle the action used.
    func freshRoot() -> Element { Element(AXUIElementCreateApplication(pid)) }

    /// Re-read a control by stable identity, CONFIRMING a disappearance with a
    /// settle + second read (a single miss == flaky/cold read, never proof). The
    /// `accept` gate matches the verb's candidate set. Returns the structural
    /// read-back AND the fresh root the second (confirming) read used, so the
    /// caller can diff witnesses off the SAME tree.
    func readbackSelf(stableIdentity key: String, named name: String,
                      accept: (ElementFacts) -> Bool) -> (ClickVerdict.SelfReadback, Element) {
        let firstRoot = freshRoot()
        switch Finder.readback(stableIdentity: key, named: name, under: firstRoot, accept: accept) {
        case let .present(f):
            return (.present(value: f.value), firstRoot)
        case .disabled:
            return (.disabled, firstRoot)
        case .absent:
            if settle > 0 { Thread.sleep(forTimeInterval: settle) }
            let secondRoot = freshRoot()
            switch Finder.readback(stableIdentity: key, named: name, under: secondRoot, accept: accept) {
            case let .present(f): return (.present(value: f.value), secondRoot)
            case .disabled: return (.disabled, secondRoot)
            case .absent: return (.goneConfirmed, secondRoot)
            }
        }
    }
}
