import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE shared `@ref` addressing (issue #7): parsing a ref handle,
/// the CSS passthrough for non-refs, and the resolve → (selector, isRef) split.
/// No socket, no browser. The staleness behavior is exercised by the actuation
/// path (a ref that matches nothing → `staleRef`), not here — this file pins the
/// pure string logic.
final class WebRefTests: XCTestCase {
    /// A ref handle `@e<digits>` parses to its bare id; the resolved selector is
    /// the `data-gh-ref` attribute the read stamped, and isRef is true.
    func testRefHandleResolvesToDataAttributeSelector() {
        XCTAssertEqual(WebRef.parse("@e5"), "e5")
        XCTAssertTrue(WebRef.isRef("@e5"))
        XCTAssertEqual(WebRef.selector(forID: "e5"), "[data-gh-ref=\"e5\"]")
        let r = WebRef.resolve("@e12")
        XCTAssertTrue(r.isRef)
        XCTAssertEqual(r.selector, "[data-gh-ref=\"e12\"]")
    }

    /// Refs are ADDITIVE — a real CSS selector is NOT a ref and passes through
    /// verbatim (the no-regression contract: `#submit`, attribute, descendant
    /// selectors all keep working).
    func testCSSSelectorsPassThroughUntouched() {
        for css in ["#submit", "input[name=q]", ".btn.primary", "a > span",
                    "div[data-id='5']", "button"] {
            XCTAssertNil(WebRef.parse(css), "\(css) must not parse as a ref")
            XCTAssertFalse(WebRef.isRef(css))
            let r = WebRef.resolve(css)
            XCTAssertFalse(r.isRef)
            XCTAssertEqual(r.selector, css, "\(css) must pass through unchanged")
        }
    }

    /// Near-miss shapes are NOT refs — `@e` with no digits, a non-numeric tail,
    /// or a bare `e5` without the sigil — so they fall through to CSS, never a
    /// half-parsed ref.
    func testNonRefShapesAreNotRefs() {
        for notRef in ["@e", "@elogin", "@e5x", "e5", "@5", "@", "@@e5", " @e5"] {
            XCTAssertNil(WebRef.parse(notRef), "\(notRef.debugDescription) must not parse as a ref")
            XCTAssertFalse(WebRef.isRef(notRef))
        }
    }

    /// The staleRef refuse describes itself honestly — names the ref and tells the
    /// caller to re-read (never implies the action happened).
    func testStaleRefDescriptionIsHonest() {
        let desc = GhostHandsError.staleRef(ref: "@e5").description
        XCTAssertTrue(desc.contains("@e5"))
        XCTAssertTrue(desc.lowercased().contains("stale ref"))
        XCTAssertTrue(desc.lowercased().contains("re-read"))
    }
}
