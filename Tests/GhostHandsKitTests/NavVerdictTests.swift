import Foundation
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE `navigate` surfaces on FABRICATED inputs. NEVER drives a
/// live browser, never calls `open`, never touches AX: every input is a plain
/// string or a `URL(string:)`. Mirrors InstallDecisionTests / ValueVerdictTests
/// (drive the pure funcs, assert enum equality).
///
/// Two pure surfaces under test:
///   A) `NavURL.normalize(_:)`  — URL validation/normalization (the refuse gate)
///                              + the `host(of:)` / `pathKey(of:)` accessors.
///   B) `NavVerdict.decide(...)` — the verdict over fabricated before/after page
///                              signals. Its signature has NO open-exit-status
///                              param, so "open returned 0" can NEVER be proof.
final class NavVerdictTests: XCTestCase {

    // MARK: - A) NavURL.normalize — keep / prepend / refuse

    func testKeepsExplicitScheme() {
        guard case let .ok(url) = NavURL.normalize("https://example.com/x") else {
            return XCTFail("explicit https must parse")
        }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(NavURL.host(of: url), "example.com")
        XCTAssertEqual(url.path, "/x")
    }

    func testAddsHttpsToBareHost() {
        guard case let .ok(url) = NavURL.normalize("example.com") else {
            return XCTFail("bare host must get https prepended")
        }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(NavURL.host(of: url), "example.com")
    }

    func testAddsHttpsToHostWithPath() {
        guard case let .ok(url) = NavURL.normalize("example.com/docs/intro") else {
            return XCTFail("bare host+path must get https prepended")
        }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(NavURL.host(of: url), "example.com")
        XCTAssertEqual(url.path, "/docs/intro")
    }

    func testLocalhostWithPort() {
        // "localhost:3000" looks scheme-like but is host:port — must get https and
        // resolve to host "localhost", not be mistaken for a scheme.
        guard case let .ok(url) = NavURL.normalize("localhost:3000") else {
            return XCTFail("localhost:port must parse as a host")
        }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(NavURL.host(of: url), "localhost")
        XCTAssertEqual(url.port, 3000)
    }

    func testTrimsWhitespace() {
        guard case let .ok(url) = NavURL.normalize("  https://example.com  ") else {
            return XCTFail("surrounding whitespace must be trimmed")
        }
        XCTAssertEqual(NavURL.host(of: url), "example.com")
    }

    func testRejectsEmpty() {
        XCTAssertEqual(NavURL.normalize(""), .malformed(""))
        XCTAssertEqual(NavURL.normalize("   "), .malformed("   "))
    }

    func testRejectsGarbage() {
        // A scheme with no host is the refuse gate; a bracket that can't parse too.
        XCTAssertEqual(NavURL.normalize("http://"), .malformed("http://"))
        if case .ok = NavURL.normalize("ht!tp://[") {
            XCTFail("unparseable garbage must be malformed")
        }
    }

    // MARK: host / pathKey normalization

    func testHostNormalization() {
        // host(of:) lowercases AND strips a leading "www.".
        let url = URL(string: "https://www.Example.COM/path")!
        XCTAssertEqual(NavURL.host(of: url), "example.com")
        // No www → just lowercased.
        XCTAssertEqual(NavURL.host(of: URL(string: "https://Example.com")!), "example.com")
        // A path-only file URL has no host.
        XCTAssertNil(NavURL.host(of: URL(string: "file:///tmp/x.html")!))
    }

    func testPathKeyStripsTrailingSlash() {
        // "/foo/" and "/foo" share a pathKey.
        XCTAssertEqual(NavURL.pathKey(of: URL(string: "https://x.com/foo/")!), "/foo")
        XCTAssertEqual(NavURL.pathKey(of: URL(string: "https://x.com/foo")!), "/foo")
        // "/" and "" both reduce to the empty "no specific path" key.
        XCTAssertEqual(NavURL.pathKey(of: URL(string: "https://x.com/")!), "")
        XCTAssertEqual(NavURL.pathKey(of: URL(string: "https://x.com")!), "")
    }

    // MARK: - B) NavVerdict.decide — verdict over fabricated page signals

    /// Mirror the live caller: normalize the request, then decide against a
    /// fabricated landed URL/title. Keeps the tests reading like the real call.
    private func decide(request: String, landed: String?, title: String? = nil)
        -> NavVerdict.Result {
        guard case let .ok(req) = NavURL.normalize(request) else {
            XCTFail("test request \(request) must normalize"); return .dispatchedUnverified(reason: "")
        }
        let landedURL = landed.flatMap { URL(string: $0) }
        return NavVerdict.decide(requestedHost: NavURL.host(of: req),
                                 requestedPath: NavURL.pathKey(of: req),
                                 landedURL: landedURL,
                                 landedTitle: title)
    }

    func testVerifiedOnHostAndPathMatch() {
        // requested example.com/docs (a doubled slash is normalized away), landed
        // https://example.com/docs → verified, evidence quotes the landed URL.
        guard case let .verified(evidence) = decide(request: "example.com//docs",
                                                    landed: "https://example.com/docs") else {
            return XCTFail("host+path match must verify")
        }
        XCTAssertTrue(evidence.contains("https://example.com/docs"),
                      "evidence must quote the landed URL: \(evidence)")
    }

    func testVerifiedHostMatchNoRequestedPath() {
        // requested example.com (no specific path) → a host match on ANY landed
        // path is the verification (host is the spine).
        if case .dispatchedUnverified = decide(request: "example.com",
                                               landed: "https://example.com/anything") {
            XCTFail("host match with no requested path must verify")
        }
    }

    func testVerifiedIgnoresWWWAndCase() {
        // requested Example.com, landed https://www.example.com/ → verified
        // (host normalized: lowercased + www stripped on both sides).
        if case .dispatchedUnverified = decide(request: "Example.com",
                                               landed: "https://www.example.com/") {
            XCTFail("www/case differences must not block a host match")
        }
    }

    func testDispatchedWhenWebAreaNotExposed() {
        // landedURL == nil (AXWebArea / its URL not exposed) → dispatched. The
        // honest under-claim: open issued but we cannot confirm.
        guard case let .dispatchedUnverified(reason) = decide(request: "example.com",
                                                              landed: nil) else {
            return XCTFail("a nil read-back URL must be dispatched-unverified")
        }
        XCTAssertTrue(reason.lowercased().contains("axwebarea")
                      || reason.lowercased().contains("page url"),
                      "reason should name the missing page URL: \(reason)")
    }

    func testDispatchedWhenHostMismatch() {
        // requested example.com, landed accounts.google.com (a redirect/SSO we
        // can't confirm is the target) → dispatched, NEVER a fake verified.
        guard case .dispatchedUnverified = decide(request: "example.com",
                                                  landed: "https://accounts.google.com") else {
            return XCTFail("a host mismatch must NEVER verify")
        }
    }

    func testDispatchedWhenPathMismatch() {
        // host matches but a SPECIFIC requested path does not → dispatched.
        guard case .dispatchedUnverified = decide(request: "example.com/docs",
                                                  landed: "https://example.com/login") else {
            return XCTFail("a requested-path mismatch must NOT verify")
        }
    }

    func testDispatchedNeverFakesOnOpenSuccess() {
        // The decide signature has NO open-exit-status param. Even a "successful"
        // open (which we model by simply NOT passing any exit status — there is
        // nowhere to pass it) with a nil landedURL is still dispatched-unverified.
        // This is the structural proof that "open returned 0" is not proof.
        XCTAssertEqual(
            NavVerdict.decide(requestedHost: "example.com", requestedPath: "",
                              landedURL: nil, landedTitle: "Example Domain"),
            .dispatchedUnverified(
                reason: "no readable page URL (AXWebArea not exposed or URL nil)"))
    }

    func testTitleCorroboratesButHostIsSpine() {
        // host match WITH a benign title still verifies (title strengthens).
        if case .dispatchedUnverified = decide(request: "example.com",
                                               landed: "https://example.com/",
                                               title: "Example Domain") {
            XCTFail("a host match with a title must verify")
        }
        // title match ALONE with a host mismatch stays dispatched — a matching
        // title can NEVER upgrade a host mismatch to verified.
        guard case .dispatchedUnverified = decide(request: "example.com",
                                                  landed: "https://evil.test/",
                                                  title: "Example Domain") else {
            return XCTFail("a title match must not rescue a host mismatch")
        }
    }

    // MARK: evidence quotes the title when present

    func testVerifiedEvidenceIncludesTitleWhenPresent() {
        guard case let .verified(evidence) = decide(request: "example.com",
                                                    landed: "https://example.com/",
                                                    title: "Example Domain") else {
            return XCTFail("host match must verify")
        }
        XCTAssertTrue(evidence.contains("Example Domain"),
                      "evidence should corroborate with the title: \(evidence)")
    }
}
