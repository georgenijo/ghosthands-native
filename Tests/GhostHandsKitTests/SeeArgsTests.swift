import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE `see` arg parse (`SeeArgs.parse`): flag extraction, the
/// `--in` × `--target` COMPOSITION, and the valueless-flag refuses. No CLI run, no
/// socket, no live app. The honesty boundary under test: `see --in <css> --target
/// <n>` threads BOTH a scope AND a renderer pick (so the leaf reads the scope off
/// the picked renderer, never the default), and a dangling `--in`/`--target`
/// REFUSES rather than silently dropping the user's intent.
final class SeeArgsTests: XCTestCase {
    private func parsedOrFail(_ args: [String],
                              file: StaticString = #filePath, line: UInt = #line) -> SeeArgs.Parsed? {
        guard case let .ok(p) = SeeArgs.parse(args) else {
            XCTFail("expected .ok for \(args), got \(SeeArgs.parse(args))", file: file, line: line)
            return nil
        }
        return p
    }

    // MARK: the headline — `--in` and `--target` compose (in EITHER order)

    func testInAndTargetCompose() {
        // The roadmap gap: `see --in <css>` must honor `--target`. Both must survive
        // the parse as a scope AND a pick — so the leaf reads the scope off the
        // picked renderer rather than the default.
        guard let p = parsedOrFail(["Cursor", "--in", "#main", "--target", "2"]) else { return }
        XCTAssertEqual(p.appSpec, "Cursor")
        XCTAssertEqual(p.scope, "#main")
        XCTAssertEqual(p.pick, .index(2))
        XCTAssertTrue(p.runOCR)
        XCTAssertNil(p.debugPort)
    }

    func testFlagOrderIndependent() {
        // `--target` before `--in`, with a title substring pick — same composition.
        guard let p = parsedOrFail(["--target", "Editor", "--in", ".panel", "Cursor"]) else { return }
        XCTAssertEqual(p.appSpec, "Cursor")
        XCTAssertEqual(p.scope, ".panel")
        XCTAssertEqual(p.pick, .match("Editor"))
    }

    func testScopeValueIsNotMistakenForApp() {
        // `--in`'s CSS value must be consumed as the scope, NOT left to become the
        // app positional (the bug a naive positional scan would have).
        guard let p = parsedOrFail(["--in", "#composer", "Brave"]) else { return }
        XCTAssertEqual(p.appSpec, "Brave")
        XCTAssertEqual(p.scope, "#composer")
        XCTAssertNil(p.pick)
    }

    // MARK: each flag stands alone / defaults

    func testBareAppHasNoScopeNoPickOCROn() {
        guard let p = parsedOrFail(["Calculator"]) else { return }
        XCTAssertEqual(p.appSpec, "Calculator")
        XCTAssertNil(p.scope)
        XCTAssertNil(p.pick)
        XCTAssertNil(p.debugPort)
        XCTAssertTrue(p.runOCR)
    }

    func testDebugPortAndNoOCRParse() {
        guard let p = parsedOrFail(["Brave", "--debug-port", "9333", "--no-ocr"]) else { return }
        XCTAssertEqual(p.debugPort, 9333)
        XCTAssertFalse(p.runOCR)
        XCTAssertNil(p.scope)
    }

    func testNoOCRAnyPosition() {
        guard let p = parsedOrFail(["--no-ocr", "--in", "#x", "App"]) else { return }
        XCTAssertEqual(p.appSpec, "App")
        XCTAssertEqual(p.scope, "#x")
        XCTAssertFalse(p.runOCR)
    }

    // MARK: valueless flags REFUSE (never silently drop the intent)

    func testValuelessInRefuses() {
        // A dangling `--in` (no CSS) must refuse, not read the whole page.
        XCTAssertEqual(SeeArgs.parse(["App", "--in"]), .refuse(.missingValue(flag: "--in")))
    }

    func testValuelessTargetRefuses() {
        // A dangling `--target` (no n|title) must refuse, not drive the default renderer.
        XCTAssertEqual(SeeArgs.parse(["App", "--target"]), .refuse(.missingValue(flag: "--target")))
    }

    func testMissingAppRefuses() {
        XCTAssertEqual(SeeArgs.parse(["--in", "#x", "--target", "2"]), .refuse(.missingApp))
        XCTAssertEqual(SeeArgs.parse([]), .refuse(.missingApp))
    }

    // MARK: a no-match `--target` is still a valid PARSE — the REFUSE is the leaf's

    func testNoMatchTargetParsesPickRefuseIsAtLeaf() {
        // The parse only validates SHAPE; "nonsuch" is a legitimate substring pick.
        // The "matched no renderer → refuse, never fall back to default" honesty is
        // enforced downstream by `CDPTargetPick.choose` returning nil (covered in
        // CDPKeySpecTests). Here we only assert the pick threads through intact.
        guard let p = parsedOrFail(["App", "--target", "nonsuch", "--in", "#x"]) else { return }
        XCTAssertEqual(p.pick, .match("nonsuch"))
        XCTAssertEqual(p.scope, "#x")
    }
}
