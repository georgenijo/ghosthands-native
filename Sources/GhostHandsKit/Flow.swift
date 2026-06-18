import Foundation

// Record / replay — a FLOW is an ordered list of STEPS, each step a single verb
// + its args. This file is the PURE core: a Codable model, pure (de)serialization,
// and a pure REPLAY POLICY. It NEVER drives a live app (that is Replay/Record),
// so it is fully hermetically testable.

/// One recorded step: a verb plus exactly the args that verb's GhostHands call
/// needs. Modelled as an enum so the JSON is self-describing and a malformed /
/// unknown step is a clean decode error (honest), never a silent skip.
public enum Step: Sendable, Equatable {
    /// `click <name> <app>`
    case click(name: String, app: String)
    /// `type <text> <field> <app>`
    case type(text: String, field: String, app: String)
    /// `set-value <value> <control> <app>`
    case setValue(value: String, control: String, app: String)
    /// `doubleclick <name> <app>`
    case doubleclick(name: String, app: String)
    /// `act <action> <name> <app>`
    case act(action: String, name: String, app: String)

    /// The verb token as it appears on the CLI / in the flow JSON.
    public var verb: String {
        switch self {
        case .click: return "click"
        case .type: return "type"
        case .setValue: return "set-value"
        case .doubleclick: return "doubleclick"
        case .act: return "act"
        }
    }

    /// The app spec this step targets (last positional on the CLI).
    public var app: String {
        switch self {
        case let .click(_, app),
             let .doubleclick(_, app):
            return app
        case let .type(_, _, app),
             let .setValue(_, _, app):
            return app
        case let .act(_, _, app):
            return app
        }
    }

    /// A short, human one-liner describing the step (for the replay log prefix),
    /// e.g. `click "OK" in Calculator`. Pure — no live read.
    public var summary: String {
        switch self {
        case let .click(name, app):
            return "click \(name.debugDescription) in \(app)"
        case let .type(text, field, app):
            return "type \(text.debugDescription) into \(field.debugDescription) in \(app)"
        case let .setValue(value, control, app):
            return "set-value \(value.debugDescription) on \(control.debugDescription) in \(app)"
        case let .doubleclick(name, app):
            return "doubleclick \(name.debugDescription) in \(app)"
        case let .act(action, name, app):
            return "act \(action) \(name.debugDescription) in \(app)"
        }
    }
}

// MARK: - Codable (tagged by "verb")

extension Step: Codable {
    private enum CodingKeys: String, CodingKey {
        case verb, name, app, text, field, value, control, action
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let verb = try c.decode(String.self, forKey: .verb)
        switch verb {
        case "click":
            self = .click(name: try c.decode(String.self, forKey: .name),
                          app: try c.decode(String.self, forKey: .app))
        case "type":
            self = .type(text: try c.decode(String.self, forKey: .text),
                         field: try c.decode(String.self, forKey: .field),
                         app: try c.decode(String.self, forKey: .app))
        case "set-value":
            self = .setValue(value: try c.decode(String.self, forKey: .value),
                             control: try c.decode(String.self, forKey: .control),
                             app: try c.decode(String.self, forKey: .app))
        case "doubleclick":
            self = .doubleclick(name: try c.decode(String.self, forKey: .name),
                                app: try c.decode(String.self, forKey: .app))
        case "act":
            self = .act(action: try c.decode(String.self, forKey: .action),
                        name: try c.decode(String.self, forKey: .name),
                        app: try c.decode(String.self, forKey: .app))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .verb, in: c,
                debugDescription: "unknown verb \(verb.debugDescription) — "
                    + "expected one of click, type, set-value, doubleclick, act")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(verb, forKey: .verb)
        switch self {
        case let .click(name, app):
            try c.encode(name, forKey: .name)
            try c.encode(app, forKey: .app)
        case let .type(text, field, app):
            try c.encode(text, forKey: .text)
            try c.encode(field, forKey: .field)
            try c.encode(app, forKey: .app)
        case let .setValue(value, control, app):
            try c.encode(value, forKey: .value)
            try c.encode(control, forKey: .control)
            try c.encode(app, forKey: .app)
        case let .doubleclick(name, app):
            try c.encode(name, forKey: .name)
            try c.encode(app, forKey: .app)
        case let .act(action, name, app):
            try c.encode(action, forKey: .action)
            try c.encode(name, forKey: .name)
            try c.encode(app, forKey: .app)
        }
    }
}

/// A flow file: a versioned, ordered list of steps. The wrapper carries a
/// `version` so a future format change is detectable rather than silently
/// mis-parsed.
public struct Flow: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var steps: [Step]

    public init(version: Int = Flow.currentVersion, steps: [Step]) {
        self.version = version
        self.steps = steps
    }
}

// MARK: - Pure (de)serialization

/// Pure flow (de)serialization + the honest malformed-file error. No file I/O
/// here — callers pass bytes — so this is hermetically testable.
public enum FlowCodec {
    /// Raised when a flow file cannot be parsed. A clean one-liner (honest
    /// error, never a crash / traceback).
    public enum FlowError: Error, CustomStringConvertible, Sendable {
        case malformed(reason: String)
        case unsupportedVersion(found: Int, expected: Int)

        public var description: String {
            switch self {
            case let .malformed(reason):
                return "not a valid flow file: \(reason)"
            case let .unsupportedVersion(found, expected):
                return "flow file version \(found) is unsupported "
                    + "(this build reads version \(expected))"
            }
        }
    }

    /// Decode a flow from raw JSON bytes. Wraps every decode failure as a clean
    /// `FlowError.malformed` — a bad file is an honest error, NEVER a crash.
    public static func decode(_ data: Data) throws -> Flow {
        let flow: Flow
        do {
            flow = try JSONDecoder().decode(Flow.self, from: data)
        } catch let err as DecodingError {
            throw FlowError.malformed(reason: Self.describe(err))
        } catch {
            throw FlowError.malformed(reason: String(describing: error))
        }
        guard flow.version == Flow.currentVersion else {
            throw FlowError.unsupportedVersion(found: flow.version,
                                               expected: Flow.currentVersion)
        }
        return flow
    }

    /// Encode a flow to pretty, stable JSON bytes (sorted keys → reproducible
    /// round-trips and human-diffable flow files).
    public static func encode(_ flow: Flow) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(flow)
    }

    private static func describe(_ err: DecodingError) -> String {
        switch err {
        case let .dataCorrupted(ctx):
            return ctx.debugDescription
        case let .keyNotFound(key, _):
            return "missing field \(key.stringValue.debugDescription)"
        case let .typeMismatch(_, ctx), let .valueNotFound(_, ctx):
            return ctx.debugDescription
        @unknown default:
            return "could not parse JSON"
        }
    }
}

// MARK: - Pure replay policy

/// The honest outcome of executing one step, reduced to the only three states
/// the replay policy cares about. Mirrors the three-state verdict of the verbs:
/// REFUSE (threw) / VERIFIED (observed) / DISPATCHED (acted, unproven).
public enum StepResult: Sendable, Equatable {
    /// The verb returned and proved an observable effect.
    case verified
    /// The verb's AX action was accepted but no effect could be observed —
    /// honest, exit-0, but NOT a success claim.
    case dispatched
    /// The verb threw (missing/ambiguous element, rejection, …) — the world
    /// diverged from the recording.
    case refused
}

/// What replay should do after a given step.
public enum ReplayDecision: Sendable, Equatable {
    /// Move on to the next step.
    case `continue`
    /// Stop replaying here (a refuse, with --keep-going off).
    case stop
}

/// The pure policy that turns a sequence of per-step results into replay
/// control-flow + a final exit code. No I/O, no live app — fully hermetic.
///
/// Rules (from the spec):
///  - A REFUSED step STOPS replay (the world diverged; blindly continuing would
///    be dishonest) UNLESS `keepGoing` is set, in which case it continues.
///  - A DISPATCHED-UNVERIFIED step does NOT abort (it acted; it just couldn't
///    prove) — it is counted so the caller knows the replay was not fully proven.
///  - Exit is 0 iff NO step REFUSED; non-zero if ANY step refused.
public enum ReplayPolicy {
    /// Decide whether to continue after a single step result.
    public static func decide(after result: StepResult,
                              keepGoing: Bool) -> ReplayDecision {
        switch result {
        case .verified, .dispatched:
            return .continue
        case .refused:
            return keepGoing ? .continue : .stop
        }
    }

    /// A summary of a completed (or stopped-early) replay run.
    public struct Summary: Sendable, Equatable {
        /// Number of steps actually executed (≤ the flow length when stopped early).
        public let executed: Int
        public let verified: Int
        public let dispatched: Int
        public let refused: Int
        /// Whether replay stopped before the end because of a refuse (keepGoing off).
        public let stoppedEarly: Bool

        public init(executed: Int, verified: Int, dispatched: Int,
                    refused: Int, stoppedEarly: Bool) {
            self.executed = executed
            self.verified = verified
            self.dispatched = dispatched
            self.refused = refused
            self.stoppedEarly = stoppedEarly
        }

        /// Exit 0 iff NO step refused; non-zero otherwise. DISPATCHED-UNVERIFIED
        /// steps never make the run fail (they acted, just unproven).
        public var exitCode: Int32 { refused > 0 ? 1 : 0 }
    }

    /// Walk a full list of per-step results under the stop-on-refuse policy and
    /// produce the run summary (incl. the honest exit code + unverified count).
    /// Pure: the live executor feeds it real results; tests feed fabricated ones.
    public static func run(_ results: [StepResult], keepGoing: Bool) -> Summary {
        var executed = 0
        var verified = 0
        var dispatched = 0
        var refused = 0
        var stoppedEarly = false

        for result in results {
            executed += 1
            switch result {
            case .verified: verified += 1
            case .dispatched: dispatched += 1
            case .refused: refused += 1
            }
            if decide(after: result, keepGoing: keepGoing) == .stop {
                stoppedEarly = true
                break
            }
        }

        return Summary(executed: executed, verified: verified,
                       dispatched: dispatched, refused: refused,
                       stoppedEarly: stoppedEarly)
    }
}
