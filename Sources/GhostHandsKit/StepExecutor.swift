import Foundation

// The LIVE bridge from a pure `Step` to the real GhostHands verb. This is the
// ONLY non-hermetic part of record/replay (it drives a real app), so it is kept
// tiny and free of policy: it executes one step, maps the honest outcome to a
// `StepResult` + a one-line verdict string, and surfaces a REFUSE as a result
// (not a thrown error) so the replay loop can apply the pure ReplayPolicy.
//
// Rendering here mirrors the CLI's report* helpers so a replayed step reads
// identically to running the verb directly — success is NEVER claimed without
// `verified`, and the word "unverified" is literally present on the dispatched
// branch.

public extension GhostHands {
    /// The result of executing one flow step: the three-state verdict plus the
    /// honest one-liner to print (already prefixed-free; the caller adds "step N").
    struct StepExecution: Sendable, Equatable {
        public let result: StepResult
        public let line: String
        public init(result: StepResult, line: String) {
            self.result = result
            self.line = line
        }
    }

    /// Execute a single recorded step against the live system. Returns the honest
    /// verdict; a GhostHandsError REFUSE is captured as `.refused` (with the
    /// error's one-liner) rather than thrown, so the replay loop stays in control.
    @MainActor
    static func execute(_ step: Step, settle: TimeInterval = 0.15) -> StepExecution {
        do {
            switch step {
            case let .click(name, app):
                let o = try click(name: name, appSpec: app, settle: settle)
                return StepExecution(result: verdict(o.verified),
                                     line: StepReport.click(o, name: name))
            case let .type(text, field, app):
                let o = try type(text: text, field: field, appSpec: app, settle: settle)
                return StepExecution(result: verdict(o.verified),
                                     line: StepReport.value(o))
            case let .setValue(value, control, app):
                let o = try setValue(value: value, control: control, appSpec: app, settle: settle)
                return StepExecution(result: verdict(o.verified),
                                     line: StepReport.value(o))
            case let .doubleclick(name, app):
                let o = try doubleclick(name: name, appSpec: app, settle: settle)
                return StepExecution(result: verdict(o.verified),
                                     line: StepReport.act(o))
            case let .act(action, name, app):
                let o = try act(action: action, name: name, appSpec: app, settle: settle)
                return StepExecution(result: verdict(o.verified),
                                     line: StepReport.act(o))
            }
        } catch let error as GhostHandsError {
            return StepExecution(result: .refused, line: "REFUSED: \(error)")
        } catch {
            return StepExecution(result: .refused,
                                 line: "REFUSED: unexpected error: \(String(describing: error))")
        }
    }

    private static func verdict(_ verified: Bool) -> StepResult {
        verified ? .verified : .dispatched
    }
}

/// Honest per-step renderers, mirroring the CLI's report* helpers (kept in the
/// Kit so replay and the direct CLI verbs read identically). Each branches on
/// `verified`; the dispatched branch always contains the word "unverified".
public enum StepReport {
    public static func click(_ o: ClickOutcome, name: String) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            return "clicked \(name.debugDescription) \(where_) — verified: \(o.evidence ?? "changed")"
        }
        return "pressed \(name.debugDescription) \(where_) — AXPress accepted; "
            + "no observable change (effect unverified)"
    }

    public static func value(_ o: ValueOutcome) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            let how = o.exact ? "verified" : "verified (changed)"
            return "\(o.verb) \(o.intended.debugDescription) into \(o.name.debugDescription) "
                + "\(where_) — \(how): \(o.evidence ?? "changed")"
        }
        let was = o.valueAfter.map { $0.debugDescription } ?? "empty"
        return "set \(o.name.debugDescription) \(where_) via AXValue — AX accepted; "
            + "field value unchanged (\(was)) (effect unverified)"
    }

    public static func act(_ o: ActOutcome) -> String {
        let where_ = "(role=\(o.role)) in \(o.app)"
        if o.verified {
            return "\(o.verbLabel) \(o.name.debugDescription) \(where_) — "
                + "verified: \(o.evidence ?? "changed")"
        }
        return "\(o.verbLabel) \(o.name.debugDescription) \(where_) — "
            + "\(o.action) accepted; no observable change (effect unverified)"
    }
}
