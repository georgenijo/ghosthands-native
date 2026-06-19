import XCTest
@testable import GhostHandsKit

/// Hermetic — issue #3: the PURE flow-report shaping (aggregate counts, JSON, JUnit
/// XML) over FABRICATED step records. No file I/O, no live replay. The status
/// labels mirror the verb verdicts exactly; the JUnit mapping never hides a refuse
/// or fakes a verified.
final class FlowReportTests: XCTestCase {

    private func rec(_ i: Int, _ status: String, _ msg: String = "ok") -> FlowStepRecord {
        FlowStepRecord(index: i, verb: "click", summary: "click \"S\(i)\" in App",
                       status: status, message: msg)
    }

    // MARK: StepResult.label mirrors the verdict

    func testStepResultLabels() {
        XCTAssertEqual(StepResult.verified.label, "verified")
        XCTAssertEqual(StepResult.dispatched.label, "dispatched")
        XCTAssertEqual(StepResult.refused.label, "refused")
    }

    // MARK: aggregate from summary

    func testReportFromSummaryCountsSkipped() {
        // A 4-step flow: 1 verified, 1 dispatched, 1 refused (stops), 1 skipped.
        let summary = ReplayPolicy.Summary(executed: 3, verified: 1, dispatched: 1,
                                           refused: 1, stoppedEarly: true)
        let steps = [rec(1, "verified"), rec(2, "dispatched"), rec(3, "refused"),
                     rec(4, "skipped")]
        let report = FlowReport(flow: "flow.json", total: 4, summary: summary, steps: steps)
        XCTAssertEqual(report.executed, 3)
        XCTAssertEqual(report.refused, 1)
        XCTAssertEqual(report.skipped, 1)         // derived from the records
        XCTAssertTrue(report.stoppedEarly)
        XCTAssertEqual(report.exitCode, 1)        // a refuse fails the run
    }

    func testCleanRunExitsZero() {
        let summary = ReplayPolicy.Summary(executed: 2, verified: 1, dispatched: 1,
                                           refused: 0, stoppedEarly: false)
        let report = FlowReport(flow: "f", total: 2, summary: summary,
                                steps: [rec(1, "verified"), rec(2, "dispatched")])
        XCTAssertEqual(report.exitCode, 0)        // dispatched never fails the run
        XCTAssertEqual(report.skipped, 0)
    }

    // MARK: JSON

    func testJSONRoundTrips() throws {
        let summary = ReplayPolicy.Summary(executed: 1, verified: 1, dispatched: 0,
                                           refused: 0, stoppedEarly: false)
        let report = FlowReport(flow: "f", total: 1, summary: summary,
                                steps: [rec(1, "verified", "value 0 → 7")])
        let json = report.json()
        let back = try JSONDecoder().decode(FlowReport.self, from: Data(json.utf8))
        XCTAssertEqual(back, report)
        XCTAssertTrue(json.contains("\"status\" : \"verified\""))
    }

    // MARK: JUnit XML

    func testJUnitMapsStatusesHonestly() {
        let summary = ReplayPolicy.Summary(executed: 3, verified: 1, dispatched: 1,
                                           refused: 1, stoppedEarly: true)
        let steps = [rec(1, "verified"), rec(2, "dispatched", "click dispatched; unverified"),
                     rec(3, "refused", "no element named X"), rec(4, "skipped")]
        let xml = FlowReport(flow: "f", total: 4, summary: summary, steps: steps).junitXML()
        // A refused step is a <failure>; failures count == refused.
        XCTAssertTrue(xml.contains("failures=\"1\""))
        XCTAssertTrue(xml.contains("<failure"))
        // A skipped step is <skipped>; skipped count surfaced.
        XCTAssertTrue(xml.contains("skipped=\"1\""))
        XCTAssertTrue(xml.contains("<skipped"))
        // A dispatched step PASSES but is flagged so it's not mistaken for proven.
        XCTAssertTrue(xml.contains("dispatched-unverified"))
        // tests == total.
        XCTAssertTrue(xml.contains("tests=\"4\""))
        XCTAssertTrue(xml.hasPrefix("<?xml"))
    }

    func testJUnitEscapesMarkup() {
        // A message/summary with XML metacharacters must be escaped, never break the
        // document or inject markup.
        let steps = [FlowStepRecord(index: 1, verb: "click",
                                    summary: "click \"<a> & 'b'\" in App",
                                    status: "refused", message: "no <element> & \"X\"")]
        let summary = ReplayPolicy.Summary(executed: 1, verified: 0, dispatched: 0,
                                           refused: 1, stoppedEarly: false)
        let xml = FlowReport(flow: "f<&>", total: 1, summary: summary, steps: steps).junitXML()
        XCTAssertFalse(xml.contains("<a>"))       // raw markup must not appear
        XCTAssertTrue(xml.contains("&lt;a&gt;"))  // it is escaped
        XCTAssertTrue(xml.contains("&amp;"))
    }
}
