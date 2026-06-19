import Foundation

// `FlowReport` — the structured PASS/FAIL report a `replay` run can emit (issue #3:
// UI-test flow-runner + report output). The replay already runs each step with an
// honest verdict and the pure `ReplayPolicy` decides the stop point + exit code;
// this adds a machine-readable record of WHAT happened per step, in two formats a
// CI consumes: a stable JSON object and JUnit XML.
//
// PURE: the report model + both serializers take fabricated step records in and
// produce a String out — no file I/O, no live app — so the whole shaping is
// hermetically testable. The live executor (Replay.swift) builds the records.
//
// HONESTY: the report mirrors the verb verdicts EXACTLY — `verified` (proven),
// `dispatched` (acted, unproven — never a success claim), `refused` (the world
// diverged → the run fails), `skipped` (a step not run because replay stopped at an
// earlier refuse). JUnit has only pass/failure/skipped, so a `dispatched` step maps
// to a PASS (consistent with the exit-0 policy — it acted) but carries a
// `<system-out>` "dispatched-unverified" note so a reader is NEVER misled into
// thinking it was proven. A `refused` step is a `<failure>`; a `skipped` step a
// `<skipped>`. The suite's failure count == the refused count == the nonzero exit.

/// One step's line in the report. `status` is the honest verdict label; `message`
/// is the verb's own verdict/refuse line (the evidence or the error).
public struct FlowStepRecord: Sendable, Equatable, Codable {
    public let index: Int          // 1-based position in the flow
    public let verb: String        // "click" / "type" / …
    public let summary: String     // human one-liner: `click "OK" in Calculator`
    public let status: String      // "verified" | "dispatched" | "refused" | "skipped"
    public let message: String     // the honest verdict / refuse line

    public init(index: Int, verb: String, summary: String, status: String, message: String) {
        self.index = index
        self.verb = verb
        self.summary = summary
        self.status = status
        self.message = message
    }
}

/// The aggregate report for one replay run.
public struct FlowReport: Sendable, Equatable, Codable {
    public let flow: String        // the flow file path/name (for the report header)
    public let total: Int          // steps in the flow
    public let executed: Int       // steps actually run (≤ total when stopped early)
    public let verified: Int
    public let dispatched: Int
    public let refused: Int
    public let skipped: Int        // steps not run (after an early stop)
    public let stoppedEarly: Bool
    public let exitCode: Int32      // 0 iff no step refused
    public let steps: [FlowStepRecord]

    public init(flow: String, total: Int, executed: Int, verified: Int,
                dispatched: Int, refused: Int, skipped: Int, stoppedEarly: Bool,
                exitCode: Int32, steps: [FlowStepRecord]) {
        self.flow = flow
        self.total = total
        self.executed = executed
        self.verified = verified
        self.dispatched = dispatched
        self.refused = refused
        self.skipped = skipped
        self.stoppedEarly = stoppedEarly
        self.exitCode = exitCode
        self.steps = steps
    }

    /// Build the report from the replay's per-step records + the pure summary, so
    /// the aggregate counts/exit always agree with `ReplayPolicy` (no second copy).
    public init(flow: String, total: Int, summary: ReplayPolicy.Summary,
                steps: [FlowStepRecord]) {
        let skipped = steps.filter { $0.status == "skipped" }.count
        self.init(flow: flow, total: total, executed: summary.executed,
                  verified: summary.verified, dispatched: summary.dispatched,
                  refused: summary.refused, skipped: skipped,
                  stoppedEarly: summary.stoppedEarly, exitCode: summary.exitCode,
                  steps: steps)
    }

    // MARK: - JSON

    /// Pretty, stable JSON (sorted keys → reproducible + diffable in CI).
    public func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    // MARK: - JUnit XML

    /// JUnit XML for CI. A `refused` step is a `<failure>`; a `skipped` step a
    /// `<skipped>`; a `dispatched` step PASSES but carries a `<system-out>` note so
    /// it is never mistaken for proven. `tests`/`failures`/`skipped` agree with the
    /// counts. Every attribute + text node is XML-escaped.
    public func junitXML() -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        let suiteAttrs = "name=\"\(Self.xmlAttr(flow))\" tests=\"\(total)\" "
            + "failures=\"\(refused)\" skipped=\"\(skipped)\""
        out += "<testsuites \(suiteAttrs)>\n"
        out += "  <testsuite \(suiteAttrs)>\n"
        for step in steps {
            let name = "\(step.index). \(step.summary)"
            out += "    <testcase name=\"\(Self.xmlAttr(name))\" classname=\"ghosthands.flow\">\n"
            switch step.status {
            case "verified":
                break   // proven → a clean pass
            case "refused":
                out += "      <failure message=\"\(Self.xmlAttr(step.message))\">"
                    + "\(Self.xmlText(step.message))</failure>\n"
            case "skipped":
                out += "      <skipped message=\"\(Self.xmlAttr(step.message))\"/>\n"
            case "dispatched":
                // PASS (it acted), but flag the unverified-ness honestly.
                out += "      <system-out>dispatched-unverified: "
                    + "\(Self.xmlText(step.message))</system-out>\n"
            default:
                // An unrecognized status is malformed data — never silently pass
                // it off as success (honesty floor). Mark it a failure.
                out += "      <failure message=\"invalid status: \(Self.xmlAttr(step.status))\">"
                    + "\(Self.xmlText(step.message))</failure>\n"
            }
            out += "    </testcase>\n"
        }
        out += "  </testsuite>\n"
        out += "</testsuites>\n"
        return out
    }

    /// Escape a string for an XML ATTRIBUTE value (quotes + the markup chars).
    static func xmlAttr(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "&", with: "&amp;")
        t = t.replacingOccurrences(of: "<", with: "&lt;")
        t = t.replacingOccurrences(of: ">", with: "&gt;")
        t = t.replacingOccurrences(of: "\"", with: "&quot;")
        return t
    }

    /// Escape a string for XML TEXT content (the markup chars; quotes are fine).
    static func xmlText(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "&", with: "&amp;")
        t = t.replacingOccurrences(of: "<", with: "&lt;")
        t = t.replacingOccurrences(of: ">", with: "&gt;")
        return t
    }
}

public extension StepResult {
    /// The honest status label this result writes into the report.
    var label: String {
        switch self {
        case .verified: return "verified"
        case .dispatched: return "dispatched"
        case .refused: return "refused"
        }
    }
}
