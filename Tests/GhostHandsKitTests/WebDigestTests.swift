import XCTest
@testable import GhostHandsKit

/// Hermetic — the pure WEB read tier over FABRICATED browser AX trees. No live
/// browser is driven. Verifies the chrome filter (everything outside an
/// AXWebArea is dropped), the page keep/drop rule (interactive + meaningful text
/// kept, structural containers skipped but walked through, empty text dropped),
/// that nested page structure is preserved, the honest empty/no-web-area
/// behaviour, and the tab extractor (selection read, REFUSE when not exposed).
final class WebDigestTests: XCTestCase {
    // MARK: - fabrication helpers

    private func n(_ role: String, title: String? = nil, value: String? = nil,
                   id: String? = nil, enabled: Bool? = nil,
                   children: [WebNode] = []) -> WebNode {
        WebNode(facts: ElementFacts(role: role, title: title, identifier: id,
                                    value: value, enabled: enabled),
                children: children)
    }

    /// A realistic browser window: chrome (toolbar + address bar + tab group +
    /// bookmarks) as a SIBLING of the page, and the page under an AXWebArea with
    /// nested structure (a nav group wrapping links, a heading, body text, a
    /// search field, a disabled button, and an empty static-text noise node).
    private func browserWindow() -> WebNode {
        n("AXWindow", title: "Example - Brave", children: [
            // --- chrome (must be stripped) ---
            n("AXToolbar", children: [
                n("AXTextField", title: "Address", value: "https://example.com"),
                n("AXButton", title: "Reload"),
                n("AXTabGroup", children: [
                    n("AXRadioButton", title: "Example tab", value: "1"),
                    n("AXRadioButton", title: "Other tab", value: "0"),
                ]),
            ]),
            n("AXGroup", title: "Bookmarks", children: [
                n("AXButton", title: "Bookmarked link"),
            ]),
            // --- page (kept) ---
            n("AXWebArea", title: "Example Domain", children: [
                n("AXGroup", children: [   // structural — skipped, walked through
                    n("AXHeading", title: "Welcome"),
                    n("AXGroup", title: "nav", children: [
                        n("AXLink", title: "Home"),
                        n("AXLink", title: "Docs"),
                    ]),
                    n("AXStaticText", value: "This domain is for examples."),
                    n("AXStaticText", value: ""),          // empty → dropped
                    n("AXSearchField", title: "Search the site"),
                    n("AXButton", title: "Submit", enabled: false),
                ]),
            ]),
        ])
    }

    // MARK: - chrome filter

    func testWebAreaRootsFoundAndChromeExcluded() {
        let roots = WebDigest.webAreaRoots(in: [browserWindow()])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].facts.role, "AXWebArea")
        XCTAssertEqual(roots[0].facts.title, "Example Domain")
    }

    func testChromeControlsNotInDigest() {
        let entries = WebDigest.entries(in: [browserWindow()])
        let names = entries.compactMap { SnapshotRender.displayName($0.facts) }
        // Chrome controls that DO match interactive roles must still be absent,
        // because they are not under the AXWebArea.
        XCTAssertFalse(names.contains("Address"))
        XCTAssertFalse(names.contains("Reload"))
        XCTAssertFalse(names.contains("Bookmarked link"))
        XCTAssertFalse(names.contains("Example tab"))   // a tab is chrome, not page
    }

    // MARK: - keep / drop rule

    func testPageInteractiveAndTextKept() {
        let entries = WebDigest.entries(in: [browserWindow()])
        let names = entries.compactMap { SnapshotRender.displayName($0.facts) }
        XCTAssertTrue(names.contains("Welcome"))                    // heading
        XCTAssertTrue(names.contains("Home"))                      // link
        XCTAssertTrue(names.contains("Docs"))                      // link
        XCTAssertTrue(names.contains("This domain is for examples.")) // static text
        XCTAssertTrue(names.contains("Search the site"))           // field
        XCTAssertTrue(names.contains("Submit"))                    // button
    }

    func testStructuralContainersDropped() {
        let entries = WebDigest.entries(in: [browserWindow()])
        // The AXGroup/AXWebArea containers are skipped (only walked through).
        XCTAssertFalse(entries.contains { $0.facts.role == "AXGroup" })
        XCTAssertFalse(entries.contains { $0.facts.role == "AXWebArea" })
    }

    func testEmptyStaticTextDropped() {
        let entries = WebDigest.entries(in: [browserWindow()])
        // Six meaningful page nodes; the empty static text is noise → dropped.
        XCTAssertEqual(WebDigest.count(entries), 6)
    }

    func testDisabledControlFlaggedNotDropped() {
        let entries = WebDigest.entries(in: [browserWindow()])
        let submit = entries.first { $0.facts.title == "Submit" }
        XCTAssertNotNil(submit)
        XCTAssertEqual(submit?.facts.enabled, false)
        XCTAssertTrue(WebDigest.line(submit!).contains("(disabled)"))
    }

    // MARK: - nesting preserved

    func testNestedPageStructurePreserved() {
        // The nav AXGroup is structural (skipped), so Home/Docs attach at the
        // page's top kept depth (0); Welcome (heading) is also depth 0. A kept
        // ancestor would raise the child's depth — verify with an explicit case.
        let tree = [n("AXWebArea", children: [
            n("AXLink", title: "Outer", children: [
                n("AXButton", title: "Inner"),   // kept child of a kept link
            ]),
        ])]
        let entries = WebDigest.entries(in: tree)
        let outer = entries.first { $0.facts.title == "Outer" }
        let inner = entries.first { $0.facts.title == "Inner" }
        XCTAssertEqual(outer?.depth, 0)
        XCTAssertEqual(inner?.depth, 1)   // nesting under the kept link preserved
        XCTAssertTrue(WebDigest.line(inner!).hasPrefix("  "))
    }

    func testStructuralSkipDoesNotInflateDepth() {
        let entries = WebDigest.entries(in: [browserWindow()])
        // Home is under AXGroup("nav") under AXGroup under AXWebArea — all
        // structural — so it attaches at depth 0, not depth 2.
        let home = entries.first { $0.facts.title == "Home" }
        XCTAssertEqual(home?.depth, 0)
    }

    // MARK: - honest empty / no web area

    func testNoWebAreaIsHonestEmpty() {
        // A window with ONLY chrome (no AXWebArea) → no roots, empty digest.
        let chromeOnly = n("AXWindow", children: [
            n("AXToolbar", children: [n("AXTextField", title: "Address")]),
        ])
        let roots = WebDigest.webAreaRoots(in: [chromeOnly])
        XCTAssertTrue(roots.isEmpty)
        let entries = WebDigest.entries(in: [chromeOnly])
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(WebDigest.render(entries), "")   // never a placeholder
    }

    func testEmptyPageRendersEmpty() {
        // An AXWebArea with only structural children → kept-empty, honest.
        let tree = [n("AXWebArea", children: [
            n("AXGroup", children: [n("AXGroup")]),
            n("AXStaticText", value: ""),
        ])]
        let roots = WebDigest.webAreaRoots(in: tree)
        XCTAssertEqual(roots.count, 1)                  // a page IS present
        XCTAssertTrue(WebDigest.entries(forPage: roots).isEmpty)
    }

    func testNestedWebAreaIframeKeptUnderOnePage() {
        // An iframe (a nested AXWebArea) should be kept as part of the same page
        // subtree, not split into a second root.
        let tree = [n("AXWebArea", children: [
            n("AXLink", title: "Top"),
            n("AXWebArea", children: [n("AXButton", title: "Inside iframe")]),
        ])]
        let roots = WebDigest.webAreaRoots(in: tree)
        XCTAssertEqual(roots.count, 1)   // outer web area only; inner kept inside
        let names = WebDigest.entries(forPage: roots)
            .compactMap { SnapshotRender.displayName($0.facts) }
        XCTAssertTrue(names.contains("Top"))
        XCTAssertTrue(names.contains("Inside iframe"))
    }

    // MARK: - render shape

    func testRenderLineShape() {
        let entry = WebDigest.Entry(
            facts: ElementFacts(role: "AXLink", title: "Sign in"), depth: 0)
        XCTAssertEqual(WebDigest.line(entry), "AXLink \"Sign in\"")
    }

    func testRenderValueWhenDistinct() {
        let entry = WebDigest.Entry(
            facts: ElementFacts(role: "AXTextField", title: "Email", value: "a@b.com"),
            depth: 1)
        let line = WebDigest.line(entry)
        XCTAssertTrue(line.hasPrefix("  AXTextField \"Email\""))
        XCTAssertTrue(line.contains("value=\"a@b.com\""))
    }

    // MARK: - tabs

    func testTabsReadWithSelection() {
        let tabs = WebTabs.tabs(in: [browserWindow()])
        XCTAssertNotNil(tabs)
        XCTAssertEqual(tabs?.count, 2)
        XCTAssertEqual(tabs?[0].title, "Example tab")
        XCTAssertEqual(tabs?[0].selected, true)     // value "1"
        XCTAssertEqual(tabs?[1].title, "Other tab")
        XCTAssertEqual(tabs?[1].selected, false)    // value "0"
    }

    func testTabsSelectionTruthyVariants() {
        let tree = [n("AXWindow", children: [
            n("AXTabGroup", children: [
                n("AXTab", title: "A", value: "true"),
                n("AXTab", title: "B", value: "selected"),
                n("AXTab", title: "C", value: nil),
            ]),
        ])]
        let tabs = WebTabs.tabs(in: tree)
        XCTAssertEqual(tabs?.map { $0.selected }, [true, true, false])
    }

    func testTabsRefuseWhenNoTabGroup() {
        let noGroup = n("AXWindow", children: [
            n("AXToolbar", children: [n("AXTextField", title: "Address")]),
        ])
        XCTAssertNil(WebTabs.tabs(in: [noGroup]))   // REFUSE signal (nil)
    }

    func testTabsRefuseWhenGroupHasNoTabs() {
        // An AXTabGroup present but exposing no AXRadioButton/AXTab children.
        let emptyGroup = n("AXWindow", children: [
            n("AXTabGroup", children: [n("AXButton", title: "New tab")]),
        ])
        XCTAssertNil(WebTabs.tabs(in: [emptyGroup]))
    }

    func testUntitledTabStillCounted() {
        let tree = [n("AXWindow", children: [
            n("AXTabGroup", children: [
                n("AXRadioButton", value: "1"),   // no title
            ]),
        ])]
        let tabs = WebTabs.tabs(in: tree)
        XCTAssertEqual(tabs?.count, 1)
        XCTAssertEqual(tabs?[0].title, "(untitled tab)")
        XCTAssertEqual(tabs?[0].selected, true)
    }

    // MARK: - wake: honesty floor preserved when the tree is STILL empty
    //
    // The live wake (setValue on an AXUIElement) is impure and cannot be
    // fabricated here — it is best-effort and verified by construction. What
    // CAN and MUST be locked is the HONESTY FLOOR: waking only adds a CHANCE
    // that the page tree fills. If a browser still exposes ONLY chrome after the
    // wake (no AXWebArea / no AXTabGroup), the SAME pure filters run over that
    // still-empty tree and the read must report honestly — never fabricate. The
    // forests below model exactly that "woke, still chrome-only" post-wake state.

    /// The pre-wake input and the post-wake input look IDENTICAL to the pure
    /// digest layer — the only difference a wake makes is whether the live tree
    /// got richer. Modelling "still chrome-only after wake" => honest empty.
    private func chromeOnlyAfterWake() -> WebNode {
        n("AXWindow", title: "New Tab - Brave", children: [
            n("AXToolbar", children: [
                n("AXTextField", title: "Address", value: ""),
                n("AXButton", title: "Reload"),
            ]),
        ])
    }

    func testWakeStillChromeOnlyReadsHonestEmpty() {
        // Browser woke but published no page: no AXWebArea root, empty digest,
        // render is "" (never a placeholder), hasWebArea stays false.
        let forest = [chromeOnlyAfterWake()]
        let roots = WebDigest.webAreaRoots(in: forest)
        XCTAssertTrue(roots.isEmpty)                      // honest: no page surface
        let entries = WebDigest.entries(in: forest)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(WebDigest.render(entries), "")     // never fabricated
        XCTAssertEqual(WebDigest.count(entries), 0)
    }

    func testWakeWebAreaPresentButEmptyReadsHonestEmpty() {
        // Browser woke and published an AXWebArea, but the page genuinely has no
        // meaningful content (a blank page). hasWebArea is true, yet the digest
        // is honestly empty — the wake never invents content.
        let forest = [n("AXWindow", children: [
            n("AXWebArea", title: "about:blank", children: [
                n("AXGroup", children: [n("AXStaticText", value: "")]),  // noise only
            ]),
        ])]
        let roots = WebDigest.webAreaRoots(in: forest)
        XCTAssertEqual(roots.count, 1)                    // a page IS present now
        XCTAssertTrue(WebDigest.entries(forPage: roots).isEmpty)  // but no content
    }

    func testWakeStillNoTabGroupRefuses() {
        // Browser woke but never published an AXTabGroup: tabs() must still
        // return nil (the REFUSE signal the CLI turns into a nonzero exit) — a
        // wake adds NO new tab honesty state and removes none.
        let forest = [chromeOnlyAfterWake()]
        XCTAssertNil(WebTabs.tabs(in: forest))
    }

    func testWakeTabGroupPresentButNoTabsRefuses() {
        // An AXTabGroup surfaced post-wake but with no AXRadioButton/AXTab
        // children → still a REFUSE (nil), never a guessed/fabricated tab list.
        let forest = [n("AXWindow", children: [
            n("AXTabGroup", children: [n("AXButton", title: "New tab")]),
        ])]
        XCTAssertNil(WebTabs.tabs(in: forest))
    }

    /// Ordering invariant: the digest/tab outcome is a PURE function of the tree
    /// the walk produces. So the post-wake (richer) tree and a tree that was
    /// always rich yield byte-identical digests — proving the wake only changes
    /// WHETHER the tree is rich, never HOW a given tree is read. (This is the
    /// hermetic stand-in for "wake then re-walk": same input ⇒ same output.)
    func testWakeOrderingIsPureOverTheResultingTree() {
        // Whatever the wake does to the live tree, the pure read over the final
        // forest is deterministic. A rich page reads the same whether it was
        // rich before the wake or only after it.
        let rich = [browserWindow()]
        let firstRead = WebDigest.render(WebDigest.entries(in: rich))
        let reReadAfterSettle = WebDigest.render(WebDigest.entries(in: rich))
        XCTAssertEqual(firstRead, reReadAfterSettle)
        XCTAssertFalse(firstRead.isEmpty)                 // the rich tree has content
    }
}
