import Foundation

// `ghosthands record <flow.json> <verb> <args...>` — execute the verb (exactly as
// running it directly) AND, only if it did NOT refuse, APPEND the step to the
// flow file (creating it if absent). This builds a flow incrementally from real,
// working steps. True passive event-capture (AXObserver) is M5 — out of scope;
// record = execute-and-append.

public extension GhostHands {
    /// The outcome of a `record` call: the step's honest verdict line, whether the
    /// step was appended (only non-refused steps are), and the new flow length.
    struct RecordRun: Sendable, Equatable {
        public let line: String
        public let result: StepResult
        public let appended: Bool
        public let stepCount: Int
        public init(line: String, result: StepResult, appended: Bool, stepCount: Int) {
            self.line = line
            self.result = result
            self.appended = appended
            self.stepCount = stepCount
        }
    }

    /// Execute `step` live, then append it to the flow at `flowPath` IF (and only
    /// if) it did not REFUSE — a refused step never enters the recording (the spec:
    /// build a flow from real, working steps). A DISPATCHED-UNVERIFIED step DID act,
    /// so it is recorded (and the line says so honestly). Throws
    /// `FlowCodec.FlowError` only for an existing-but-malformed flow file, or a
    /// write failure.
    @MainActor
    static func record(_ step: Step, into flowPath: String,
                       settle: TimeInterval = 0.15) throws -> RecordRun {
        let exec = execute(step, settle: settle)

        guard exec.result != .refused else {
            // Refused: the verb proved nothing happened — do NOT pollute the flow.
            // Report the honest refusal line; nothing appended.
            let count = (try? loadFlow(at: flowPath))?.steps.count ?? 0
            return RecordRun(line: exec.line, result: exec.result,
                             appended: false, stepCount: count)
        }

        var flow = try loadOrNewFlow(at: flowPath)
        flow.steps.append(step)
        try writeFlow(flow, to: flowPath)
        return RecordRun(line: exec.line, result: exec.result,
                         appended: true, stepCount: flow.steps.count)
    }

    /// Load an existing flow, or return a fresh empty one if the file is absent.
    /// An existing-but-malformed file is an honest error (we refuse to clobber it).
    static func loadOrNewFlow(at path: String) throws -> Flow {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Flow(steps: [])
        }
        return try loadFlow(at: path)
    }

    /// Write a flow to disk as stable pretty JSON. A write failure is an honest
    /// `FlowCodec.FlowError.malformed`-style error (never a silent loss).
    static func writeFlow(_ flow: Flow, to path: String) throws {
        let data = try FlowCodec.encode(flow)
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw FlowCodec.FlowError.malformed(
                reason: "cannot write flow to \(path.debugDescription): "
                    + error.localizedDescription)
        }
    }
}
