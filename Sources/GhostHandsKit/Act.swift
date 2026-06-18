import ApplicationServices
import AXorcist
import Foundation

/// The outcome of an ACTION verb (`doubleclick`, `act`) — honest about whether
/// the action's EFFECT was VERIFIED (observed change) or merely DISPATCHED (the
/// AX action did not throw, but nothing observable changed). Mirrors
/// `ClickOutcome`: `axAccepted` is the dispatch; `verified` is the observed
/// world-change, computed from the read-back/witness, never from the dispatch.
public struct ActOutcome: Sendable, Equatable {
    public let app: String
    public let name: String
    public let role: String
    public let action: String        // the AX action string actually performed
    public let verbLabel: String     // human verb for the report ("double-clicked")
    public let axAccepted: Bool
    public let verified: Bool
    public let evidence: String?
    public let valueBefore: String?
    public let valueAfter: String?
    public let witnessName: String?
    public let witnessBefore: String?
    public let witnessAfter: String?

    public init(app: String, name: String, role: String, action: String,
                verbLabel: String, axAccepted: Bool, verified: Bool,
                evidence: String?, valueBefore: String? = nil, valueAfter: String? = nil,
                witnessName: String? = nil, witnessBefore: String? = nil,
                witnessAfter: String? = nil) {
        self.app = app
        self.name = name
        self.role = role
        self.action = action
        self.verbLabel = verbLabel
        self.axAccepted = axAccepted
        self.verified = verified
        self.evidence = evidence
        self.valueBefore = valueBefore
        self.valueAfter = valueAfter
        self.witnessName = witnessName
        self.witnessBefore = witnessBefore
        self.witnessAfter = witnessAfter
    }
}

extension GhostHands {
    /// `doubleclick "<name>" <app>` — honest double-activation for rows/items/
    /// files that OPEN on a double click. Prefers the AXOpen action (the AX
    /// equivalent of a double click); verifies via the SAME read-back + witness
    /// machinery as click. If AXOpen lands but nothing observable changes (a row
    /// that opens a doc in ANOTHER process we can't witness in-app), it is
    /// honestly DISPATCHED-UNVERIFIED.
    @MainActor
    public static func doubleclick(name: String, appSpec: String,
                                   locator: LocatorSpec = .none,
                                   settle: TimeInterval = 0.15) throws -> ActOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        let element: Element
        let facts: ElementFacts
        switch Finder.resolve(named: name, under: target.element, accept: Finder.isOpenable,
                              locator: locator) {
        case let .element(found, foundFacts):
            element = found
            facts = foundFacts
        case let .ambiguous(candidates):
            throw GhostHandsError.ambiguousMatch(name: name, candidates: candidates)
        case let .indexOutOfRange(requested, count):
            throw GhostHandsError.locatorIndexOutOfRange(name: name, requested: requested, count: count)
        case .none:
            throw GhostHandsError.elementNotFound(name: name, app: target.name)
        }

        // Prefer AXOpen (the true double-click equivalent); fall back to AXPress
        // only when the control advertises it but not AXOpen. A control that
        // advertises NEITHER cannot be honestly double-activated → REFUSE.
        let action: String
        if facts.supportsOpen {
            action = "AXOpen"
        } else if facts.supportsPress {
            action = "AXPress"
        } else {
            throw GhostHandsError.actionRejected(name: name, action: "AXOpen")
        }

        return try performAndVerify(action: action, element: element, facts: facts,
                                    name: name, target: target, verbLabel: "double-clicked",
                                    direction: nil, accept: Finder.isOpenable, settle: settle)
    }

    /// `act <action> "<name>" <app>` — invoke a named AX action. Friendly names
    /// map to AX strings via `ActionName`. The control must ADVERTISE the action
    /// (pre-checked) or we REFUSE early rather than throw-and-guess. Verified by
    /// read-back where observable (increment/decrement by direction, pick/open/
    /// confirm/cancel by witness/structural change); honestly DISPATCHED when the
    /// action has no in-AX observable (the canonical case: raise / show-menu).
    @MainActor
    public static func act(action friendly: String, name: String, appSpec: String,
                           locator: LocatorSpec = .none,
                           settle: TimeInterval = 0.15) throws -> ActOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        guard let axAction = ActionName.axAction(for: friendly) else {
            throw GhostHandsError.unknownAction(friendly)
        }
        let target = try Target.resolve(appSpec)

        let element: Element
        let facts: ElementFacts
        switch Finder.resolve(named: name, under: target.element, accept: Finder.isSettable,
                              locator: locator) {
        case let .element(found, foundFacts):
            element = found
            facts = foundFacts
        case let .ambiguous(candidates):
            throw GhostHandsError.ambiguousMatch(name: name, candidates: candidates)
        case let .indexOutOfRange(requested, count):
            throw GhostHandsError.locatorIndexOutOfRange(name: name, requested: requested, count: count)
        case .none:
            throw GhostHandsError.elementNotFound(name: name, app: target.name)
        }

        // PRE-CHECK: the control must advertise the requested action. Refusing
        // early (with what IS supported) is more honest than dispatching an
        // unsupported action and guessing at the throw.
        guard facts.supports(axAction) else {
            throw GhostHandsError.wrongActionForControl(
                name: name, action: axAction, supported: facts.supportedActions)
        }

        let direction: DirectionVerdict.Direction?
        switch axAction {
        case "AXIncrement": direction = .up
        case "AXDecrement": direction = .down
        default: direction = nil
        }

        return try performAndVerify(action: axAction, element: element, facts: facts,
                                    name: name, target: target, verbLabel: "act \(friendly)",
                                    direction: direction, accept: Finder.isSettable, settle: settle)
    }

    /// Shared dispatch + verify for `doubleclick`/`act`. Performs `action`, reads
    /// the control back off a fresh tree, and decides the verdict:
    /// - increment/decrement → DirectionVerdict (moved in the requested direction),
    /// - everything else → ClickVerdict (self value flip / disabled / gone-
    ///   confirmed, else one scoped witness changed).
    /// A throw from performAction → REFUSE (.actionRejected). No throw + no
    /// observed change → DISPATCHED-UNVERIFIED (honest, never inferred success).
    ///
    /// `accept` MUST be the SAME candidate gate used to RESOLVE the target, so the
    /// read-back can re-find the control it just acted on. Hardcoding a narrower
    /// gate here (e.g. `isSettable` for `doubleclick`, whose `isOpenable` resolve
    /// admits AXRow/AXCell that `isSettable` rejects) would make the read-back
    /// blind to its own target: it would `.absent` → `.goneConfirmed` and fabricate
    /// a VERIFIED "no longer present" for a row that is still on screen. The gate
    /// is threaded through so a still-present row reads back `.present` (unchanged)
    /// → honest DISPATCHED, never a false success.
    @MainActor
    static func performAndVerify(action: String, element: Element, facts: ElementFacts,
                                 name: String, target: Target, verbLabel: String,
                                 direction: DirectionVerdict.Direction?,
                                 accept: @escaping (ElementFacts) -> Bool,
                                 settle: TimeInterval) throws -> ActOutcome {
        let role = facts.role ?? "AXUnknown"
        let before = facts.value
        let stableIdentity = NameMatch.stableIdentityKey(facts)

        let probe = EffectProbe(pid: target.pid, settle: settle)
        let witnessBefore = probe.captureBefore(of: element)

        do {
            _ = try element.performAction(action)
        } catch {
            // AX rejected the action — honest REFUSE (no fabricated success).
            throw GhostHandsError.actionRejected(name: name, action: action)
        }

        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        let (readback, readbackRoot) =
            probe.readbackSelf(stableIdentity: stableIdentity, named: name,
                               accept: accept)
        let after: String?
        if case let .present(value) = readback { after = value } else { after = nil }

        // increment/decrement verify by NUMERIC DIRECTION (a value that saturated
        // at a bound did not move → DISPATCHED, an honest "landed but no change",
        // distinguishable from a reject).
        if let direction {
            switch DirectionVerdict.decide(before: before, after: after, direction: direction) {
            case let .verified(evidence):
                return ActOutcome(app: target.name, name: name, role: role, action: action,
                                  verbLabel: verbLabel, axAccepted: true, verified: true,
                                  evidence: evidence, valueBefore: before, valueAfter: after)
            case .dispatched:
                return ActOutcome(app: target.name, name: name, role: role, action: action,
                                  verbLabel: verbLabel, axAccepted: true, verified: false,
                                  evidence: nil, valueBefore: before, valueAfter: after)
            }
        }

        // Everything else: the click verdict (self change / disabled / gone, else
        // one scoped witness changed). raise/show-menu typically yield nothing
        // observable → the canonical DISPATCHED-UNVERIFIED.
        let witnessDiff = probe.diff(witnessBefore, readbackRoot: readbackRoot)
        let verdict = ClickVerdict.decide(selfBefore: before, readback: readback,
                                          witnessDiff: witnessDiff)
        switch verdict {
        case let .verified(evidence, witness):
            return ActOutcome(app: target.name, name: name, role: role, action: action,
                              verbLabel: verbLabel, axAccepted: true, verified: true,
                              evidence: evidence, valueBefore: before, valueAfter: after,
                              witnessName: witness?.name, witnessBefore: witness?.before,
                              witnessAfter: witness?.after)
        case .dispatched:
            return ActOutcome(app: target.name, name: name, role: role, action: action,
                              verbLabel: verbLabel, axAccepted: true, verified: false,
                              evidence: nil, valueBefore: before, valueAfter: after)
        }
    }
}
