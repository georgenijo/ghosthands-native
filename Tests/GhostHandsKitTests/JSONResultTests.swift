import CoreGraphics
import Foundation
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE `--json` envelope core over FABRICATED outcomes. NO live
/// app, NO CLI process: we hand-build each `*Outcome` / `*Result`, run the same
/// `JSONResult.from*` shaper the CLI runners call, and assert the envelope's
/// status / evidence / fields / encoded bytes.
///
/// THE INVARIANT UNDER TEST (the whole point of the task): the JSON status
/// MIRRORS the human verdict EXACTLY — a dispatched outcome shapes to
/// `"dispatched"` and NEVER `"verified"`, a refuse shapes to `"refused"`, a read
/// to `"ok"`, an assert to `"pass"`/`"fail"`. There is no path here that can
/// upgrade an unproven action to a proven one.
final class JSONResultTests: XCTestCase {

    // MARK: - encoder + escaping (the byte-stable, deterministic core)

    func testEnvelopeKeyOrderIsStableAndNilsAreOmitted() {
        let r = JSONResult(verb: "click", status: .verified, app: "Calc",
                           target: "7", evidence: "display 0 → 7",
                           fields: [("role", .string("AXButton"))])
        // verb, status, app, target, evidence, [value omitted], fields, [error omitted]
        XCTAssertEqual(
            r.encoded(),
            "{\"verb\":\"click\",\"status\":\"verified\",\"app\":\"Calc\","
            + "\"target\":\"7\",\"evidence\":\"display 0 → 7\","
            + "\"fields\":{\"role\":\"AXButton\"}}")
    }

    func testFieldsAlwaysPresentEvenWhenEmpty() {
        let r = JSONResult(verb: "key", status: .dispatched, app: "Safari", target: "return")
        // No fields → an empty object, never a missing key.
        XCTAssertTrue(r.encoded().contains("\"fields\":{}"))
        // No evidence/value/error → omitted entirely (not null).
        XCTAssertFalse(r.encoded().contains("null"))
        XCTAssertFalse(r.encoded().contains("evidence"))
        XCTAssertFalse(r.encoded().contains("error"))
    }

    func testStringEscapingHandlesQuotesNewlinesTabsAndControls() {
        let nasty = "a\"b\\c\nd\te\u{08}\u{01}"
        let encoded = GHJSONValue.encodeString(nasty)
        XCTAssertEqual(encoded, "\"a\\\"b\\\\c\\nd\\te\\b\\u0001\"")
    }

    func testEvidenceWithEmbeddedNewlineDoesNotBreakTheLine() {
        let r = JSONResult(verb: "extract", status: .ok, app: "X",
                           evidence: "row1\nrow2")
        // The whole envelope is ONE line — the newline is escaped, not literal.
        XCTAssertFalse(r.encoded().contains("\n"))
        XCTAssertTrue(r.encoded().contains("row1\\nrow2"))
    }

    func testNumberAndBoolAndDoubleEncoding() {
        let obj = GHJSONValue.object([
            ("i", .int(42)),
            ("b", .bool(true)),
            ("whole", .double(3.0)),
            ("frac", .double(0.5)),
            ("zero", .double(0.0)),
        ])
        XCTAssertEqual(obj.encoded(),
                       "{\"i\":42,\"b\":true,\"whole\":3,\"frac\":0.5,\"zero\":0}")
    }

    func testNonFiniteDoubleEncodesAsNullNeverACrashOrFakeZero() {
        XCTAssertEqual(GHJSONValue.double(.infinity).encoded(), "null")
        XCTAssertEqual(GHJSONValue.double(.nan).encoded(), "null")
    }

    func testNestedArrayOfObjectsEncodesInOrder() {
        let arr = GHJSONValue.array([
            .object([("n", .string("a"))]),
            .object([("n", .string("b"))]),
        ])
        XCTAssertEqual(arr.encoded(), "[{\"n\":\"a\"},{\"n\":\"b\"}]")
    }

    /// The encoded envelope is valid JSON that Foundation can parse back — proof
    /// the hand-rolled encoder agrees with the spec (not just our own eyes).
    func testEncodedEnvelopeRoundTripsThroughJSONSerialization() throws {
        let r = JSONResult(verb: "find", status: .ok, app: "Calc", target: "7",
                           fields: [("count", .int(2)),
                                    ("hits", .array([.object([("role", .string("AXButton"))])]))])
        let data = Data(r.encoded().utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["verb"] as? String, "find")
        XCTAssertEqual(obj?["status"] as? String, "ok")
        let fields = obj?["fields"] as? [String: Any]
        XCTAssertEqual(fields?["count"] as? Int, 2)
    }

    // MARK: - THE HONESTY INVARIANT: verified vs dispatched never confused

    func testClickVerifiedShapesToVerifiedWithEvidence() {
        let o = ClickOutcome(app: "Calc", name: "7", role: "AXButton",
                             axAccepted: true, verified: true,
                             evidence: "display 0 → 7", valueBefore: "0",
                             valueAfter: "7")
        let r = JSONResult.fromClick(o, name: "7")
        XCTAssertEqual(r.status, .verified)
        XCTAssertEqual(r.evidence, "display 0 → 7")
        XCTAssertEqual(r.app, "Calc")
        XCTAssertEqual(r.target, "7")
    }

    func testClickDispatchedShapesToDispatchedWithNoEvidence() {
        // AX accepted but NO observed change → the human "unverified" line. The
        // envelope MUST say "dispatched", NEVER "verified", and carry no evidence.
        let o = ClickOutcome(app: "Calc", name: "7", role: "AXButton",
                             axAccepted: true, verified: false,
                             evidence: "display 0 → 7" /* present but unproven */,
                             valueBefore: "0", valueAfter: "0")
        let r = JSONResult.fromClick(o, name: "7")
        XCTAssertEqual(r.status, .dispatched)
        XCTAssertNil(r.evidence, "a dispatched click must not leak evidence")
    }

    func testTypeVerbLabelIsTheCLIVerbNotThePhrasing() {
        let o = ValueOutcome(app: "Safari", name: "Search", role: "AXTextField",
                             verb: "typed", intended: "swift", axAccepted: true,
                             verified: true, exact: true, valueBefore: "",
                             valueAfter: "swift", evidence: "reads back \"swift\"")
        let r = JSONResult.fromValue(o, verb: "type")
        XCTAssertEqual(r.verb, "type")
        XCTAssertEqual(r.status, .verified)
        XCTAssertEqual(r.value, "swift")
        // the human phrasing ("typed") is preserved in fields, not as the verb
        XCTAssertTrue(r.fields.contains { $0.key == "phrasing" && $0.value == .string("typed") })
    }

    func testSetValueDispatchedStaysDispatched() {
        let o = ValueOutcome(app: "System Settings", name: "Wi-Fi", role: "AXCheckBox",
                             verb: "set", intended: "on", axAccepted: true,
                             verified: false, exact: false, valueBefore: "0",
                             valueAfter: "0", evidence: nil)
        let r = JSONResult.fromValue(o, verb: "set-value")
        XCTAssertEqual(r.verb, "set-value")
        XCTAssertEqual(r.status, .dispatched)
        XCTAssertNil(r.evidence)
    }

    func testActVerifiedAndDispatched() {
        let v = ActOutcome(app: "X", name: "Vol", role: "AXSlider", action: "AXIncrement",
                           verbLabel: "incremented", axAccepted: true, verified: true,
                           evidence: "value 3 → 4")
        XCTAssertEqual(JSONResult.fromAct(v, verb: "act").status, .verified)

        let d = ActOutcome(app: "X", name: "Menu", role: "AXButton", action: "AXShowMenu",
                           verbLabel: "showed menu", axAccepted: true, verified: false,
                           evidence: nil)
        let rd = JSONResult.fromAct(d, verb: "act")
        XCTAssertEqual(rd.status, .dispatched)
        XCTAssertNil(rd.evidence)
        XCTAssertTrue(rd.fields.contains { $0.key == "action" && $0.value == .string("AXShowMenu") })
    }

    func testFocusUnreadableFocusedAfterStaysDispatched() {
        let o = FocusOutcome(app: "Safari", name: "Search", role: "AXTextField",
                             axAccepted: true, verified: false, focusedAfter: nil,
                             evidence: nil)
        let r = JSONResult.fromFocus(o)
        XCTAssertEqual(r.status, .dispatched)
        // a nil focusedAfter is OMITTED, never serialized as a fabricated false
        XCTAssertFalse(r.fields.contains { $0.key == "focusedAfter" })
    }

    func testKeyIsAlwaysDispatchedNeverVerified() {
        let o = KeyOutcome(app: "Safari", spec: "cmd+s", keyName: "s",
                           mode: .invisible, dispatched: true)
        let r = JSONResult.fromKey(o)
        XCTAssertEqual(r.status, .dispatched, "a key has no observable — never verified")
        XCTAssertEqual(r.target, "cmd+s")
        XCTAssertTrue(r.fields.contains { $0.key == "mode" && $0.value == .string("invisible") })
    }

    func testWindowRaiseIsAlwaysDispatched() {
        let o = WindowRaiseOutcome(app: "Preview", windowTitle: "Doc", windowID: 12,
                                   axAccepted: true, verified: false)
        XCTAssertEqual(JSONResult.fromWindowRaise(o).status, .dispatched)
    }

    func testWindowMutateClampedIsDispatchedNotVerified() {
        // The OS clamped the set → honest DISPATCHED (the human line too), NEVER
        // a fake verified even though something landed.
        let o = WindowMutateOutcome(
            app: "Notes", verb: "resize", windowTitle: "Untitled", windowID: 7,
            axAccepted: true, verified: false, clamped: true,
            frameBefore: CGRect(x: 0, y: 0, width: 400, height: 300),
            frameAfter: CGRect(x: 0, y: 0, width: 500, height: 400))
        let r = JSONResult.fromWindowMutate(o)
        XCTAssertEqual(r.status, .dispatched)
        XCTAssertTrue(r.fields.contains { $0.key == "clamped" && $0.value == .bool(true) })
        XCTAssertNil(r.evidence)
    }

    func testPixelDispatchedAndVerified() {
        let v = PixelOutcome(app: "Calc", verb: "click-at", x: 10, y: 20,
                             dispatched: true, verified: true, observable: true,
                             changedFraction: 0.25)
        XCTAssertEqual(JSONResult.fromPixel(v).status, .verified)

        let d = PixelOutcome(app: "Calc", verb: "click-at", x: 10, y: 20,
                             dispatched: true, verified: false, observable: false,
                             changedFraction: 0)
        let rd = JSONResult.fromPixel(d)
        XCTAssertEqual(rd.status, .dispatched)
        XCTAssertTrue(rd.fields.contains { $0.key == "observable" && $0.value == .bool(false) })
    }

    func testScrollUnobservableStaysDispatched() {
        let o = ScrollOutcome(app: "Safari", container: "Sidebar", direction: .down,
                              amount: 1, via: "wheel", dispatched: true, verified: false,
                              observable: false, positionBefore: nil, positionAfter: nil)
        XCTAssertEqual(JSONResult.fromScroll(o).status, .dispatched)
    }

    func testClipboardWriteVerifiedAndDispatched() {
        let v = ClipboardOutcome(intended: "hello", readback: "hello", verified: true)
        let rv = JSONResult.fromClipboard(v)
        XCTAssertEqual(rv.status, .verified)
        XCTAssertEqual(rv.value, "hello")

        let d = ClipboardOutcome(intended: "hello", readback: "world", verified: false)
        XCTAssertEqual(JSONResult.fromClipboard(d).status, .dispatched)
    }

    func testWebActuateVerdictDrivesStatusNotTheWord() {
        let v = GhostHands.WebActuateResult(
            app: "Brave", selector: "#go", verb: "clicked",
            verdict: .verified(evidence: "navigated"), port: 9222)
        let rv = JSONResult.fromWebActuate(v)
        XCTAssertEqual(rv.verb, "web click")
        XCTAssertEqual(rv.status, .verified)

        let d = GhostHands.WebActuateResult(
            app: "Brave", selector: "input", verb: "filled",
            verdict: .dispatchedUnverified(reason: "value could not be read back"),
            port: 9222)
        let rd = JSONResult.fromWebActuate(d)
        XCTAssertEqual(rd.verb, "web fill")
        XCTAssertEqual(rd.status, .dispatched)
    }

    func testNavigateUnverifiedStaysDispatchedWithReasonAsEvidence() {
        let o = GhostHands.NavigateOutcome(
            app: "Brave", requestedURL: "https://example.com", landedURL: nil,
            landedTitle: nil, verified: false, evidence: "no readable page URL",
            autoPicked: true)
        let r = JSONResult.fromNavigate(o)
        XCTAssertEqual(r.status, .dispatched)
        // the honest unverified REASON is surfaced as evidence (it never upgrades
        // the status — status is driven by `verified`)
        XCTAssertEqual(r.evidence, "no readable page URL")
    }

    func testInstallUnverifiedStaysDispatched() {
        let o = GhostHands.InstallOutcome(
            appName: "Foo.app", dest: "/Applications", installedPath: "/Applications/Foo.app",
            verified: false, bundleIdentifier: nil)
        XCTAssertEqual(JSONResult.fromInstall(o).status, .dispatched)
    }

    // MARK: - assert (pass | fail)

    func testAssertPassAndFailMapToPassFail() {
        let pass = GhostHands.AssertOutcome(
            app: "Calc", name: "Display",
            verdict: .pass("PASS: \"Display\" value == \"0\""),
            observed: .present(count: 1, value: "0"))
        let rp = JSONResult.fromAssert(pass)
        XCTAssertEqual(rp.status, .pass)
        XCTAssertEqual(rp.value, "0")

        let fail = GhostHands.AssertOutcome(
            app: "Calc", name: "Display",
            verdict: .fail("FAIL: \"Display\" value is \"7\", expected \"0\""),
            observed: .present(count: 1, value: "7"))
        XCTAssertEqual(JSONResult.fromAssert(fail).status, .fail)
    }

    // MARK: - reads (ok)

    func testFindHitIsOkWithHitsInFields() {
        let facts = ElementFacts(role: "AXButton", title: "7", enabled: true)
        let o = GhostHands.FindOutcome(app: "Calc", query: "7", hits: [facts])
        let r = JSONResult.fromFind(o)
        XCTAssertEqual(r.status, .ok)
        XCTAssertTrue(r.fields.contains { $0.key == "found" && $0.value == .bool(true) })
        XCTAssertTrue(r.fields.contains { $0.key == "count" && $0.value == .int(1) })
    }

    func testWaitIsOkBecauseATimeoutIsARefuseNeverAnOutcome() {
        let o = WaitOutcome(app: "TextEdit", name: "Save", wantedGone: false,
                            elapsed: 1.5, polls: 10)
        let r = JSONResult.fromWait(o)
        XCTAssertEqual(r.status, .ok)
        XCTAssertTrue(r.fields.contains { $0.key == "polls" && $0.value == .int(10) })
    }

    func testClipboardReadEmptyIsOkAndNeverFabricatesAValue() {
        let r = JSONResult.fromClipboardRead("")
        XCTAssertEqual(r.status, .ok)
        XCTAssertNil(r.value, "an empty clipboard must not fabricate a value")
        XCTAssertTrue(r.fields.contains { $0.key == "empty" && $0.value == .bool(true) })

        let r2 = JSONResult.fromClipboardRead("hi")
        XCTAssertEqual(r2.value, "hi")
        XCTAssertTrue(r2.fields.contains { $0.key == "empty" && $0.value == .bool(false) })
    }

    // MARK: - refuse (refused — same message, carries `error`)

    func testRefusalCarriesTheSameMessageAndStatusRefused() {
        let err = GhostHandsError.elementNotFound(name: "Nope", app: "Calc")
        let r = JSONResult.fromRefusal(verb: "click", message: "\(err)", target: "Nope")
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.error, "\(err)")
        XCTAssertEqual(r.target, "Nope")
        // a refuse envelope carries `error` and encodes it
        XCTAssertTrue(r.encoded().contains("\"error\":"))
        XCTAssertTrue(r.encoded().contains("\"status\":\"refused\""))
    }

    // MARK: - replay / record mirror the exit policy

    func testReplayRefusedStepsShapeToRefused() {
        let summary = ReplayPolicy.Summary(executed: 3, verified: 1, dispatched: 1,
                                           refused: 1, stoppedEarly: true)
        let run = GhostHands.ReplayRun(summary: summary, total: 5)
        let r = JSONResult.fromReplay(run)
        XCTAssertEqual(r.status, .refused, "a run with a refused step is not clean")
        XCTAssertNotNil(r.error)
        XCTAssertTrue(r.fields.contains { $0.key == "refused" && $0.value == .int(1) })
    }

    func testReplayCleanRunShapesToOk() {
        let summary = ReplayPolicy.Summary(executed: 2, verified: 2, dispatched: 0,
                                           refused: 0, stoppedEarly: false)
        let run = GhostHands.ReplayRun(summary: summary, total: 2)
        let r = JSONResult.fromReplay(run)
        XCTAssertEqual(r.status, .ok)
        XCTAssertNil(r.error)
    }
}
