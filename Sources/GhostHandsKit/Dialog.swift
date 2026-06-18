import ApplicationServices
import AXorcist
import Foundation

// MARK: - Pure core (no AX) — fabricated facts in, honest result out.

/// The PURE, AX-free detection + dismiss-verdict core for the `dialog` verb. It
/// operates over a fabricated `SnapshotNode` subtree (the same node shape the
/// snapshot walker builds from a real tree), so finding the dialog node,
/// extracting its title/message text + button names, and deciding the
/// dismiss-verdict are all hermetically unit-testable with no live app.
///
/// HONESTY: it reports exactly what the nodes carry. A subtree with no modal
/// node yields `nil` (the live verb turns that into a `.noDialog` REFUSE, never a
/// fabricated dialog); the dismiss-verdict promotes to VERIFIED only when the
/// detected dialog is OBSERVED gone on a fresh read — a still-present dialog is
/// honestly DISPATCHED, never a faked success.
public enum DialogScan {
    /// Roles/subroles that mark a node as a modal sheet / alert / dialog. A
    /// `sheet` (AXSheet) is the document-modal panel; `dialog`/`systemDialog`
    /// arrive as an AXWindow whose SUBROLE is AXDialog / AXSystemDialog (a modal
    /// alert). We match on BOTH the role (AXSheet) and the subrole (AXDialog /
    /// AXSystemDialog) so a save-sheet, a print panel, and a system alert all
    /// resolve, while an ordinary window (subrole AXStandardWindow) does not.
    public static let dialogRoles: Set<String> = ["AXSheet"]
    public static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]

    /// True iff a node's facts mark it as a modal dialog/sheet/alert (by role OR
    /// subrole). Pure — drives both the live walk and the tests.
    public static func isDialog(_ f: ElementFacts) -> Bool {
        if let role = f.role, dialogRoles.contains(role) { return true }
        if let subrole = f.subrole, dialogSubroles.contains(subrole) { return true }
        return false
    }

    /// What we detected about a modal dialog: the node itself plus the extracted,
    /// human-facing facts. Pure values, so the report is rendered with no AX.
    public struct Detected: Sendable, Equatable {
        /// The dialog node (with its full subtree) — the scope every `--click`
        /// button resolution is confined to (never the whole app).
        public let node: SnapshotNode
        /// The dialog's title (AXTitle of the modal node), nil when untitled.
        public let title: String?
        /// The collected message/body STATIC TEXT inside the dialog, in pre-order,
        /// deduplicated and excluding the title — the human "what it says". Empty
        /// when the dialog exposes no static text (honest, never fabricated).
        public let messageLines: [String]
        /// The names of the dialog's BUTTONS, in pre-order — the choices a caller
        /// must respond with. Disabled buttons are included but flagged (a dialog
        /// whose default is disabled is a real, observable state).
        public let buttons: [Button]

        public init(node: SnapshotNode, title: String?, messageLines: [String],
                    buttons: [Button]) {
            self.node = node
            self.title = title
            self.messageLines = messageLines
            self.buttons = buttons
        }
    }

    /// One button choice inside a dialog — its display name + whether it is
    /// enabled. The name is the same display label `click` resolves against, so a
    /// `--click "<name>"` targets exactly what `dialog` printed.
    public struct Button: Sendable, Equatable {
        public let name: String
        public let enabled: Bool
        public init(name: String, enabled: Bool) {
            self.name = name
            self.enabled = enabled
        }
    }

    /// Find the FRONTMOST modal dialog in a forest of window subtrees and extract
    /// its facts. "Frontmost" here = the FIRST dialog found in pre-order across
    /// the forest (the live walk feeds windows already in AX front-to-back order,
    /// and a sheet is a child of its host window, so the first hit is the topmost
    /// modal). Returns nil when no node in the forest is a modal dialog — the
    /// honest "no dialog" that the live verb turns into a REFUSE.
    public static func detect(in forest: [SnapshotNode]) -> Detected? {
        for root in forest {
            if let node = firstDialogNode(root) {
                return extract(from: node)
            }
        }
        return nil
    }

    /// The first modal node in a subtree, pre-order. A window that is ITSELF a
    /// dialog (subrole AXDialog) matches; otherwise we descend to find a child
    /// AXSheet. We do NOT recurse INTO a dialog once found (its own buttons are
    /// not nested dialogs), so the returned node carries the full modal subtree.
    static func firstDialogNode(_ node: SnapshotNode) -> SnapshotNode? {
        if isDialog(node.facts) { return node }
        for child in node.children {
            if let hit = firstDialogNode(child) { return hit }
        }
        return nil
    }

    /// Extract the title, message lines, and buttons from a (already-identified)
    /// dialog node's subtree. Pure pre-order walk over the fabricated children.
    static func extract(from node: SnapshotNode) -> Detected {
        let title = node.facts.title.flatMap { $0.isEmpty ? nil : $0 }

        var messageLines: [String] = []
        var seenMessages = Set<String>()
        var buttons: [Button] = []
        var seenButtons = Set<String>()

        func walk(_ n: SnapshotNode, isRoot: Bool) {
            let f = n.facts
            // A nested dialog/sheet is a DIFFERENT modal — do not pull its buttons
            // up into this one. (The root itself is the dialog; only descendants
            // are filtered.)
            if !isRoot, isDialog(f) { return }

            if isButtonRole(f) {
                if let name = buttonName(f), !name.isEmpty, !seenButtons.contains(name) {
                    seenButtons.insert(name)
                    buttons.append(Button(name: name, enabled: f.enabled ?? true))
                }
            } else if f.role == "AXStaticText" {
                if let text = staticTextValue(f), !text.isEmpty,
                   text != title, !seenMessages.contains(text) {
                    seenMessages.insert(text)
                    messageLines.append(text)
                }
            }
            for child in n.children { walk(child, isRoot: false) }
        }
        walk(node, isRoot: true)

        return Detected(node: node, title: title, messageLines: messageLines,
                        buttons: buttons)
    }

    /// True iff these facts denote a pressable button choice in a dialog — an
    /// AXButton, or a control that advertises AXPress (a popup/checkbox inside a
    /// sheet is not a dismissal "button"; we keep the gate to genuine buttons so
    /// the printed choice list is the set of dismiss-able actions).
    static func isButtonRole(_ f: ElementFacts) -> Bool {
        f.role == "AXButton"
    }

    /// A button's display label — title, else description, else its value (some
    /// AXButtons carry their label as AXDescription). Pure, mirrors the snapshot
    /// display precedence but scoped to a button.
    static func buttonName(_ f: ElementFacts) -> String? {
        for candidate in [f.title, f.descriptionText, f.value] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// A static-text node's human string — its value (AXStaticText carries the
    /// displayed string as AXValue), else its title.
    static func staticTextValue(_ f: ElementFacts) -> String? {
        for candidate in [f.value, f.title, f.descriptionText] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }
}

/// The PURE dismiss-verdict for `dialog --click` — promotes the press to
/// VERIFIED only when the dialog we detected is OBSERVED gone on a fresh read;
/// a dialog still present after the press is honestly DISPATCHED-UNVERIFIED.
///
/// Kept AX-free so the dialog-gone / still-present / not-observable arms are
/// hermetically unit-testable. The input is whether a modal dialog is still
/// present on the re-read — and, crucially, whether the re-read could be
/// performed AT ALL. NEVER fakes a dismissal: a re-read that could not be
/// performed is an honest under-claim (DISPATCHED), NEVER a verified dismissal.
public enum DismissVerdict {
    /// What a fresh post-press read of the app found regarding a modal dialog.
    public enum Readback: Sendable, Equatable {
        /// A modal dialog is STILL present on the re-read — the press did not
        /// dismiss it (or opened a follow-up modal). Honest under-claim.
        case stillPresent
        /// NO modal dialog is present on the re-read — the dialog was dismissed.
        case gone
        /// The re-read itself COULD NOT BE PERFORMED — the AXWindows attribute
        /// returned an error (a read FAILURE, distinct from an app that genuinely
        /// has no windows / no modal). We must NOT treat an unreadable tree as
        /// "gone": doing so would fabricate a verified dismissal off a transient AX
        /// glitch. So this maps to DISPATCHED (honest under-claim), never VERIFIED.
        case notObservable
    }

    public enum Result: Sendable, Equatable {
        /// The dialog was OBSERVED gone — VERIFIED (dialog dismissed).
        case verified(evidence: String)
        /// The press was accepted but a modal dialog is still present, OR the
        /// re-read could not be performed — honest DISPATCHED-UNVERIFIED, never a
        /// faked dismissal.
        case dispatched
    }

    /// Decide from the post-press read-back. `button` is the pressed button name
    /// (for the evidence string). A `.gone` read promotes to VERIFIED; both
    /// `.stillPresent` AND `.notObservable` stay DISPATCHED — only a positively
    /// OBSERVED-gone modal verifies a dismissal.
    public static func decide(button: String, readback: Readback) -> Result {
        switch readback {
        case .gone:
            return .verified(evidence: "dialog dismissed (no modal present after pressing \(button.debugDescription))")
        case .stillPresent, .notObservable:
            return .dispatched
        }
    }
}

// MARK: - The outcome shapes handed to the CLI.

/// The result of a `dialog <app>` DETECT — the dialog's text + button names, all
/// pure values rendered by the CLI. A detect that found no dialog never produces
/// this (the verb throws `.noDialog`); so a `DialogReport` always describes a
/// real, observed modal.
public struct DialogReport: Sendable, Equatable {
    public let app: String
    public let title: String?
    public let messageLines: [String]
    public let buttons: [DialogScan.Button]

    public init(app: String, detected: DialogScan.Detected) {
        self.app = app
        self.title = detected.title
        self.messageLines = detected.messageLines
        self.buttons = detected.buttons
    }
}

/// The result of a `dialog <app> --click "<button>"` RESPOND — honest about
/// whether the dismissal was VERIFIED (the modal is observed gone) or merely
/// DISPATCHED (AXPress accepted; the dialog is still present / not observable).
/// Mirrors `ClickOutcome`'s honesty split.
public struct DialogClickOutcome: Sendable, Equatable {
    public let app: String
    public let button: String
    public let role: String
    /// AXPress was accepted by the button (the dispatch). NOT proof of dismissal.
    public let axAccepted: Bool
    /// The modal dialog was OBSERVED gone after the press — the only honest
    /// VERIFIED for a dismissal.
    public let verified: Bool
    /// Human evidence for the VERIFIED case, nil when dispatched-unverified.
    public let evidence: String?

    public init(app: String, button: String, role: String, axAccepted: Bool,
                verified: Bool, evidence: String?) {
        self.app = app
        self.button = button
        self.role = role
        self.axAccepted = axAccepted
        self.verified = verified
        self.evidence = evidence
    }
}

// MARK: - The AX-touching walk + live verb.

/// Builds a `SnapshotNode` forest of the app's window subtrees for the dialog
/// scan, BOUNDED by a depth cap + visited-set (AXorcist's `children()` is for
/// SEARCH, not a clean tree, and a cyclic AX subtree must never overflow the
/// stack). Mirrors `SnapshotWalker`'s bounded walk but is its own small walker so
/// the dialog tier never depends on snapshot's render shape.
@MainActor
enum DialogWalker {
    /// Far deeper than any real dialog subtree, trivially below the overflow
    /// point (mirrors Finder.maxSearchDepth's rationale).
    static let maxDepth = 80

    /// Walk an app root into a forest of window subtrees (front-to-back AX order),
    /// each a real parent→child tree via strict children. Returns nil when the
    /// AXWindows attribute could NOT be read (a read FAILURE), distinct from an
    /// app that genuinely has zero windows (an empty forest). Callers MUST NOT
    /// collapse the two: a `nil` is "could not observe", an `[]` is "no windows".
    static func forest(of appRoot: Element) -> [SnapshotNode]? {
        guard let windows = appRoot.windows() else { return nil }
        var visited = Set<Element>()
        return windows.map { node(from: $0, depth: 0, visited: &visited) }
    }

    private static func node(from element: Element, depth: Int,
                             visited: inout Set<Element>) -> SnapshotNode {
        let facts = Finder.facts(of: element)
        guard depth < maxDepth, !visited.contains(element) else {
            return SnapshotNode(facts: facts, depth: depth, children: [])
        }
        visited.insert(element)
        let kids = element.children(strict: true) ?? []
        let childNodes = kids.map { node(from: $0, depth: depth + 1, visited: &visited) }
        return SnapshotNode(facts: facts, depth: depth, children: childNodes)
    }

    /// Re-read the app and answer the post-press dismiss witness as a TRI-STATE:
    /// a modal is still present, the modal is gone, OR the tree could not be read
    /// at all. A fresh root each call (never a stale handle).
    ///
    /// The third arm is the honesty fix: when `forest` returns nil (the AXWindows
    /// attribute errored — a transient read FAILURE, not a windowless app), we
    /// report `.notObservable` rather than silently treating an unreadable tree as
    /// "no modal → gone → VERIFIED". A read failure must NEVER fabricate a
    /// dismissal; it maps to DISPATCHED-UNVERIFIED downstream.
    static func observeDialog(pid: pid_t) -> DismissVerdict.Readback {
        let root = Element(AXUIElementCreateApplication(pid))
        guard let forest = forest(of: root) else {
            // windows() == nil ⇒ AX read failure ⇒ we could NOT observe the modal.
            return .notObservable
        }
        return DialogScan.detect(in: forest) != nil ? .stillPresent : .gone
    }
}

extension GhostHands {
    /// `dialog <app>` — DETECT the frontmost modal sheet / alert / dialog in the
    /// app and report its title, message text, and the names of its buttons.
    /// REFUSES (`.noDialog`) when no modal is present — never fabricates a dialog.
    ///
    /// Bounded AX walk (depth cap + visited set), then the PURE `DialogScan` does
    /// the detection/extraction over the read-back facts.
    @MainActor
    public static func dialog(appSpec: String) throws -> DialogReport {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)
        // A nil forest is an AXWindows READ FAILURE (not a windowless app); refuse
        // with `.windowListUnreadable` rather than collapse it into a `.noDialog`
        // that would mislead the caller into thinking no modal exists.
        guard let forest = DialogWalker.forest(of: target.element) else {
            throw GhostHandsError.windowListUnreadable(app: target.name)
        }
        guard let detected = DialogScan.detect(in: forest) else {
            throw GhostHandsError.noDialog(app: target.name)
        }
        return DialogReport(app: target.name, detected: detected)
    }

    /// `dialog <app> --click "<button>"` — RESPOND to the detected modal by
    /// pressing the named button WITHIN it, then WITNESS the dismissal.
    ///
    /// Honesty order:
    /// 1. DETECT the modal (REFUSE `.noDialog` if none — never press into nothing).
    /// 2. Resolve the named button SCOPED TO THE DIALOG node (refuse not-found /
    ///    ambiguous, exactly as `click`), so a button on a background window can
    ///    never be the thing we press.
    /// 3. AXPress it (REFUSE `.actionRejected` on a rejected press).
    /// 4. WITNESS: re-read the app — a modal dialog GONE → VERIFIED (dismissed);
    ///    still present → DISPATCHED-UNVERIFIED. Never a faked dismissal.
    @MainActor
    public static func dialogClick(button: String, appSpec: String,
                                   settle: TimeInterval = 0.2) throws -> DialogClickOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        // 1. DETECT the modal — refuse if there is no dialog to respond to. A nil
        //    forest is a READ FAILURE (refuse `.windowListUnreadable`), distinct
        //    from a readable-but-modal-free tree (refuse `.noDialog`).
        guard let forest = DialogWalker.forest(of: target.element) else {
            throw GhostHandsError.windowListUnreadable(app: target.name)
        }
        guard DialogScan.detect(in: forest) != nil else {
            throw GhostHandsError.noDialog(app: target.name)
        }

        // 2. Resolve the named button SCOPED TO THE DIALOG. We re-pin the modal's
        //    live AX element (the frontmost AXSheet/AXDialog) and resolve the
        //    button UNDER it — never under the whole app — so a same-named button
        //    on a background window cannot be targeted. The bounded `Finder.resolve`
        //    is reused as-is (its options carry the depth cap / cycle guard).
        guard let dialogElement = frontmostDialogElement(of: target.element) else {
            // The pure scan saw a dialog but we could not re-pin the live element —
            // refuse rather than fall back to an app-wide button search.
            throw GhostHandsError.noDialog(app: target.name)
        }

        let element: Element
        let facts: ElementFacts
        switch Finder.resolve(named: button, under: dialogElement) {
        case let .element(found, foundFacts):
            element = found
            facts = foundFacts
        case let .ambiguous(candidates):
            throw GhostHandsError.ambiguousMatch(name: button, candidates: candidates)
        case .none:
            throw GhostHandsError.elementNotFound(name: button, app: target.name)
        }
        let role = facts.role ?? "AXUnknown"

        // 3. Press the button — a rejected press is an honest REFUSE.
        guard element.press() else {
            throw GhostHandsError.actionRejected(name: button, action: "AXPress")
        }

        // 4. WITNESS the dismissal off a FRESH read. Settle first (a modal tears
        //    down a beat after the press); a single "gone" read is the proof a
        //    dialog dismissal needs (unlike a control's disappearance, a modal
        //    going away IS the observable effect — there is no stale-handle
        //    ambiguity at the window level). The witness is TRI-STATE: a tree we
        //    could NOT read (.notObservable) is an honest DISPATCHED, never a
        //    fabricated VERIFIED off a transient AX glitch.
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        let readback = DialogWalker.observeDialog(pid: target.pid)
        let verdict = DismissVerdict.decide(button: button, readback: readback)

        switch verdict {
        case let .verified(evidence):
            return DialogClickOutcome(app: target.name, button: button, role: role,
                                      axAccepted: true, verified: true, evidence: evidence)
        case .dispatched:
            return DialogClickOutcome(app: target.name, button: button, role: role,
                                      axAccepted: true, verified: false, evidence: nil)
        }
    }

    /// Re-pin the live frontmost modal AX element (the FIRST AXSheet/AXDialog in
    /// the app's windows, pre-order) so a button resolve is scoped to it. Bounded
    /// by the same depth cap / visited set as the walk. Returns nil when no modal
    /// element is found live (the caller refuses rather than search app-wide).
    @MainActor
    static func frontmostDialogElement(of appRoot: Element) -> Element? {
        let windows = appRoot.windows() ?? []
        var visited = Set<Element>()
        for window in windows {
            if let hit = firstDialogElement(window, depth: 0, visited: &visited) {
                return hit
            }
        }
        return nil
    }

    @MainActor
    private static func firstDialogElement(_ element: Element, depth: Int,
                                           visited: inout Set<Element>) -> Element? {
        guard depth < DialogWalker.maxDepth, !visited.contains(element) else { return nil }
        visited.insert(element)
        if DialogScan.isDialog(Finder.facts(of: element)) { return element }
        let kids = element.children(strict: true) ?? []
        for child in kids {
            if let hit = firstDialogElement(child, depth: depth + 1, visited: &visited) {
                return hit
            }
        }
        return nil
    }
}
