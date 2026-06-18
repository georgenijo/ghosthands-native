import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE half of `web wait` (issue #10): the URL glob matcher, the
/// per-kind probe expression, and the met-decision over a FABRICATED probe dict.
/// No socket, no browser, no clock. The live deadline loop reuses the same
/// `WaitVerdict`-style fence as AX `wait`, which is itself tested in WaitVerdictTests.
final class WebWaitTests: XCTestCase {
    // MARK: URL glob matcher — `*` is the only wildcard; metachars stay literal

    func testGlobExactAndWildcard() {
        XCTAssertTrue(WebGlob.matches(glob: "https://example.com/",
                                      text: "https://example.com/"))
        XCTAssertFalse(WebGlob.matches(glob: "https://example.com/",
                                       text: "https://example.com/page"))
        XCTAssertTrue(WebGlob.matches(glob: "*iana*",
                                      text: "https://www.iana.org/help"))
        XCTAssertTrue(WebGlob.matches(glob: "https://*.org/*",
                                      text: "https://www.iana.org/help/example"))
        XCTAssertTrue(WebGlob.matches(glob: "*", text: "anything at all"))
        XCTAssertTrue(WebGlob.matches(glob: "*/help", text: "https://x/help"))
        XCTAssertFalse(WebGlob.matches(glob: "*/help", text: "https://x/helpdesk"))
    }

    func testGlobTreatsRegexMetacharsAsLiteral() {
        // `?` `.` `+` are LITERAL (not regex) — only `*` is special.
        XCTAssertTrue(WebGlob.matches(glob: "https://x/?q=1",
                                      text: "https://x/?q=1"))
        XCTAssertFalse(WebGlob.matches(glob: "https://x/?q=1",
                                       text: "https://x/Xq=1"))   // `?` is not "any char"
        XCTAssertTrue(WebGlob.matches(glob: "a.b+c", text: "a.b+c"))
        XCTAssertFalse(WebGlob.matches(glob: "a.b+c", text: "aXbXc"))
    }

    // MARK: probe expression — embeds the needle safely, reads the right fact

    func testProbeExpressionsCoverEachKind() {
        XCTAssertTrue(WebWait.probeExpression(for: .text("hi")).contains("innerText"))
        XCTAssertTrue(WebWait.probeExpression(for: .selector("#x", gone: false))
            .contains("querySelector"))
        XCTAssertTrue(WebWait.probeExpression(for: .url("*")).contains("location.href"))
        XCTAssertTrue(WebWait.probeExpression(for: .load(.domcontentloaded))
            .contains("readyState"))
        let idle = WebWait.probeExpression(for: .load(.networkidle))
        XCTAssertTrue(idle.contains("getEntriesByType"))     // resource-timing heuristic
        XCTAssertTrue(idle.contains("\(WebWait.networkIdleQuietMs)"))
        // The needle is embedded as a JSON string literal (quoted) — never raw.
        XCTAssertTrue(WebWait.probeExpression(for: .text("a\"b")).contains("\"a\\\"b\""))
    }

    // MARK: met-decision over fabricated probe dicts

    func testTextAndSelectorMet() {
        XCTAssertTrue(WebWait.met(kind: .text("x"), observation: ["present": true]))
        XCTAssertFalse(WebWait.met(kind: .text("x"), observation: ["present": false]))
        XCTAssertTrue(WebWait.met(kind: .selector("#x", gone: false),
                                  observation: ["present": true]))
        // --gone inverts: met iff ABSENT.
        XCTAssertTrue(WebWait.met(kind: .selector("#x", gone: true),
                                  observation: ["present": false]))
        XCTAssertFalse(WebWait.met(kind: .selector("#x", gone: true),
                                   observation: ["present": true]))
    }

    func testUrlMetUsesGlob() {
        XCTAssertTrue(WebWait.met(kind: .url("*iana*"),
                                  observation: ["href": "https://www.iana.org/"]))
        XCTAssertFalse(WebWait.met(kind: .url("*iana*"),
                                   observation: ["href": "https://example.com/"]))
    }

    func testLoadMetReadsReady() {
        XCTAssertTrue(WebWait.met(kind: .load(.networkidle), observation: ["ready": true]))
        XCTAssertFalse(WebWait.met(kind: .load(.domcontentloaded), observation: ["ready": false]))
    }

    /// An unreadable / empty probe is honestly NOT met (a notYet poll), never a
    /// fabricated success — so a missing field can't flip a wait to met.
    func testEmptyProbeIsNotMet() {
        XCTAssertFalse(WebWait.met(kind: .text("x"), observation: [:]))
        XCTAssertFalse(WebWait.met(kind: .url("*"), observation: [:]))   // no href → not met
        XCTAssertFalse(WebWait.met(kind: .load(.networkidle), observation: [:]))
    }

    // MARK: label + gone sense feed the report and the timeout refuse

    func testLabelAndGoneSense() {
        XCTAssertEqual(WebWait.label(.text("Welcome")), "text \"Welcome\"")
        XCTAssertEqual(WebWait.label(.url("*ok*")), "url \"*ok*\"")
        XCTAssertEqual(WebWait.label(.selector("#x", gone: true)), "selector \"#x\" (gone)")
        XCTAssertEqual(WebWait.label(.load(.networkidle)), "load networkidle")
        XCTAssertTrue(WebWait.isGone(.selector("#x", gone: true)))
        XCTAssertFalse(WebWait.isGone(.selector("#x", gone: false)))
        XCTAssertFalse(WebWait.isGone(.text("x")))
    }
}
