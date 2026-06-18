import Foundation

// `ghosthands replay <flow.json>` — execute each step IN ORDER, print one honest
// line per step, STOP on the first REFUSE (unless --keep-going), and exit 0 iff
// no step refused. The control-flow + exit code come entirely from the pure
// ReplayPolicy; this file just does the live dispatch + the line printing.

public extension GhostHands {
    /// What a replay run reports back to the CLI: the pure summary (for the exit
    /// code + unverified count) — every per-step line is emitted via `onStep` as
    /// it happens so the operator sees progress live.
    struct ReplayRun: Sendable, Equatable {
        public let summary: ReplayPolicy.Summary
        public let total: Int
        public init(summary: ReplayPolicy.Summary, total: Int) {
            self.summary = summary
            self.total = total
        }
    }

    /// Load + replay a flow file. `onStep(index, total, line)` is called once per
    /// executed step (1-based index) with the honest verdict line; the loop stops
    /// on the first refuse unless `keepGoing`. Throws `FlowCodec.FlowError` only
    /// for a missing/malformed flow file (an honest error, not a crash).
    @MainActor
    static func replay(flowPath: String,
                       keepGoing: Bool = false,
                       settle: TimeInterval = 0.15,
                       onStep: (_ index: Int, _ total: Int, _ line: String) -> Void)
        throws -> ReplayRun
    {
        let flow = try loadFlow(at: flowPath)
        let total = flow.steps.count

        // Drive the live dispatch + per-step lines here, but collect the honest
        // verdicts and let the SAME pure, hermetically-tested `ReplayPolicy.run`
        // decide the stop point + build the Summary. This keeps the path that
        // actually runs identical to the path FlowTests verifies (no second copy
        // of the count/stop/exit logic to silently drift).
        var results: [StepResult] = []
        results.reserveCapacity(total)
        for step in flow.steps {
            let exec = execute(step, settle: settle)
            results.append(exec.result)
            onStep(results.count, total, exec.line)

            if ReplayPolicy.decide(after: exec.result, keepGoing: keepGoing) == .stop {
                break
            }
        }

        let summary = ReplayPolicy.run(results, keepGoing: keepGoing)
        return ReplayRun(summary: summary, total: total)
    }

    /// Read + decode a flow file from disk. A missing file or unreadable bytes is
    /// an honest `FlowCodec.FlowError.malformed`, never a crash.
    static func loadFlow(at path: String) throws -> Flow {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FlowCodec.FlowError.malformed(
                reason: "cannot read \(path.debugDescription): \(error.localizedDescription)")
        }
        return try FlowCodec.decode(data)
    }
}
