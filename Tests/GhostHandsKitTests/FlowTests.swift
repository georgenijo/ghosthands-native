import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE record/replay core: Flow (de)serialization round-trip, an
/// honest error on a malformed flow file (never a crash), and the replay POLICY
/// that decides continue/stop + the final exit from a list of fabricated per-step
/// results. NEVER drives a live app — every fact here is fabricated.
final class FlowTests: XCTestCase {

    // MARK: - Round-trip serialize / parse

    private let everyVerb: [Step] = [
        .click(name: "OK", app: "Calculator"),
        .type(text: "alice", field: "Username", app: "Safari"),
        .setValue(value: "on", control: "Wi-Fi", app: "System Settings"),
        .doubleclick(name: "report.pdf", app: "Finder"),
        .act(action: "increment", name: "Volume", app: "System Settings"),
    ]

    func testRoundTripEveryVerb() throws {
        let flow = Flow(steps: everyVerb)
        let data = try FlowCodec.encode(flow)
        let back = try FlowCodec.decode(data)
        XCTAssertEqual(back, flow, "encode→decode must be the identity")
        XCTAssertEqual(back.steps, everyVerb)
        XCTAssertEqual(back.version, Flow.currentVersion)
    }

    func testDecodedStepArgsArePreservedExactly() throws {
        // Args with quotes/spaces survive the round-trip verbatim.
        let flow = Flow(steps: [.type(text: "a \"quoted\" b", field: "Name x", app: "App Y")])
        let back = try FlowCodec.decode(try FlowCodec.encode(flow))
        guard case let .type(text, field, app) = back.steps[0] else {
            return XCTFail("expected a type step")
        }
        XCTAssertEqual(text, "a \"quoted\" b")
        XCTAssertEqual(field, "Name x")
        XCTAssertEqual(app, "App Y")
    }

    func testStepJSONIsTaggedByVerb() throws {
        let data = try FlowCodec.encode(Flow(steps: [.click(name: "OK", app: "Calculator")]))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"verb\" : \"click\""), "step JSON must carry its verb tag")
    }

    // MARK: - Malformed flow → honest error, not a crash

    func testNotJSONIsMalformedError() {
        let data = Data("this is not json".utf8)
        XCTAssertThrowsError(try FlowCodec.decode(data)) { err in
            guard case FlowCodec.FlowError.malformed = err else {
                return XCTFail("expected .malformed, got \(err)")
            }
        }
    }

    func testUnknownVerbIsMalformedError() {
        // A step naming a verb we don't know is a clean decode error (honest).
        let data = Data(#"{"version":1,"steps":[{"verb":"teleport","app":"X"}]}"#.utf8)
        XCTAssertThrowsError(try FlowCodec.decode(data)) { err in
            guard case FlowCodec.FlowError.malformed = err else {
                return XCTFail("expected .malformed for unknown verb, got \(err)")
            }
        }
    }

    func testMissingRequiredFieldIsMalformedError() {
        // A click step with no app → honest error, never a crash or a guess.
        let data = Data(#"{"version":1,"steps":[{"verb":"click","name":"OK"}]}"#.utf8)
        XCTAssertThrowsError(try FlowCodec.decode(data)) { err in
            guard case FlowCodec.FlowError.malformed = err else {
                return XCTFail("expected .malformed for missing field, got \(err)")
            }
        }
    }

    func testWrongVersionIsRejected() {
        let data = Data(#"{"version":999,"steps":[]}"#.utf8)
        XCTAssertThrowsError(try FlowCodec.decode(data)) { err in
            guard case let FlowCodec.FlowError.unsupportedVersion(found, expected) = err else {
                return XCTFail("expected .unsupportedVersion, got \(err)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(expected, Flow.currentVersion)
        }
    }

    func testFlowErrorDescriptionsAreCleanOneLiners() {
        XCTAssertFalse(FlowCodec.FlowError.malformed(reason: "x").description.isEmpty)
        XCTAssertFalse(FlowCodec.FlowError.unsupportedVersion(found: 2, expected: 1)
            .description.isEmpty)
    }

    func testEmptyFlowRoundTrips() throws {
        let back = try FlowCodec.decode(try FlowCodec.encode(Flow(steps: [])))
        XCTAssertEqual(back.steps, [])
    }

    // MARK: - Per-result decision (stop-on-refuse + --keep-going override)

    func testVerifiedAndDispatchedContinue() {
        XCTAssertEqual(ReplayPolicy.decide(after: .verified, keepGoing: false), .continue)
        XCTAssertEqual(ReplayPolicy.decide(after: .dispatched, keepGoing: false), .continue)
    }

    func testRefuseStopsByDefault() {
        XCTAssertEqual(ReplayPolicy.decide(after: .refused, keepGoing: false), .stop)
    }

    func testKeepGoingOverridesStopOnRefuse() {
        XCTAssertEqual(ReplayPolicy.decide(after: .refused, keepGoing: true), .continue)
    }

    // MARK: - Whole-run policy (control flow + exit code + unverified count)

    func testAllVerifiedExitsZero() {
        let s = ReplayPolicy.run([.verified, .verified, .verified], keepGoing: false)
        XCTAssertEqual(s.executed, 3)
        XCTAssertEqual(s.verified, 3)
        XCTAssertEqual(s.dispatched, 0)
        XCTAssertEqual(s.refused, 0)
        XCTAssertFalse(s.stoppedEarly)
        XCTAssertEqual(s.exitCode, 0)
    }

    func testAnUnverifiedStepExitsZeroButIsCounted() {
        // DISPATCHED-UNVERIFIED acted; it does not abort and does not fail the run,
        // but it is surfaced in the count so the caller knows it was not proven.
        let s = ReplayPolicy.run([.verified, .dispatched, .verified], keepGoing: false)
        XCTAssertEqual(s.executed, 3, "an unverified step does NOT abort")
        XCTAssertEqual(s.dispatched, 1)
        XCTAssertFalse(s.stoppedEarly)
        XCTAssertEqual(s.exitCode, 0, "unverified is exit 0 — not a failure")
    }

    func testARefusedStepExitsNonZero() {
        let s = ReplayPolicy.run([.verified, .refused, .verified], keepGoing: false)
        XCTAssertNotEqual(s.exitCode, 0, "any refuse → non-zero exit")
        XCTAssertEqual(s.exitCode, 1)
    }

    func testStopOnRefuseHaltsRemainingSteps() {
        // step 2 refuses → steps 3,4 are NEVER executed (the world diverged).
        let s = ReplayPolicy.run([.verified, .refused, .verified, .verified],
                                 keepGoing: false)
        XCTAssertEqual(s.executed, 2, "must stop at the refuse")
        XCTAssertEqual(s.verified, 1)
        XCTAssertEqual(s.refused, 1)
        XCTAssertTrue(s.stoppedEarly)
        XCTAssertEqual(s.exitCode, 1)
    }

    func testKeepGoingExecutesAllStepsThroughARefuse() {
        let s = ReplayPolicy.run([.verified, .refused, .dispatched, .verified],
                                 keepGoing: true)
        XCTAssertEqual(s.executed, 4, "--keep-going runs every step")
        XCTAssertEqual(s.verified, 2)
        XCTAssertEqual(s.dispatched, 1)
        XCTAssertEqual(s.refused, 1)
        XCTAssertFalse(s.stoppedEarly)
        // Still a failure exit: a step DID refuse, --keep-going only changes flow.
        XCTAssertEqual(s.exitCode, 1)
    }

    func testEmptyRunIsExitZero() {
        let s = ReplayPolicy.run([], keepGoing: false)
        XCTAssertEqual(s.executed, 0)
        XCTAssertEqual(s.exitCode, 0)
        XCTAssertFalse(s.stoppedEarly)
    }

    // MARK: - Step metadata (pure, used by the live loop / record)

    func testStepVerbTokensMatchTheCLI() {
        XCTAssertEqual(Step.click(name: "a", app: "b").verb, "click")
        XCTAssertEqual(Step.type(text: "a", field: "b", app: "c").verb, "type")
        XCTAssertEqual(Step.setValue(value: "a", control: "b", app: "c").verb, "set-value")
        XCTAssertEqual(Step.doubleclick(name: "a", app: "b").verb, "doubleclick")
        XCTAssertEqual(Step.act(action: "open", name: "b", app: "c").verb, "act")
    }

    func testStepAppIsAlwaysTheLastPositional() {
        XCTAssertEqual(Step.type(text: "a", field: "b", app: "TheApp").app, "TheApp")
        XCTAssertEqual(Step.act(action: "open", name: "b", app: "TheApp").app, "TheApp")
    }
}
