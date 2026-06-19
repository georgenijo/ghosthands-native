import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE OCR pieces: the Vision-normalized → screen-rect coordinate
/// flip and the text matcher. The Vision call itself (`GhostHands.ocr`) needs a real
/// screenshot and is exercised live, never in a unit test.
final class OCRTests: XCTestCase {

    /// A normalized (bottom-left) Vision box maps to a screen (top-left) rect using
    /// the window frame: x/width scale directly; y is flipped about the frame height
    /// and offset by the window's on-screen origin.
    func testScreenRectFlipsAndOffsets() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let frame = CGRect(x: 100, y: 50, width: 200, height: 400)
        let r = OCRGeometry.screenRect(normBox: box, windowFrame: frame)
        XCTAssertEqual(r.minX, 120, accuracy: 0.0001)
        XCTAssertEqual(r.width, 60, accuracy: 0.0001)
        XCTAssertEqual(r.height, 160, accuracy: 0.0001)
        // y: frame.minY + (1 - 0.2 - 0.4) * 400 = 50 + 160 = 210
        XCTAssertEqual(r.minY, 210, accuracy: 0.0001)
    }

    /// A box at the bottom-left of the image maps to the bottom-left of the window on
    /// screen (top-left origin → large y), never a negative coordinate.
    func testScreenRectBottomLeftBox() {
        let box = CGRect(x: 0, y: 0, width: 0.2, height: 0.1)
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let r = OCRGeometry.screenRect(normBox: box, windowFrame: frame)
        XCTAssertEqual(r.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(r.minY, 800 - 80, accuracy: 0.0001)   // (1-0-0.1)*800 = 720
    }

    func testMatchExactWinsOverSubstring() {
        XCTAssertEqual(OCRMatch.choose(["Send", "Send message"], query: "Send"), .one(0))
    }

    func testMatchSubstringUnique() {
        XCTAssertEqual(OCRMatch.choose(["Open project", "Clone repo"], query: "clone"), .one(1))
    }

    func testMatchAmbiguousAndNone() {
        XCTAssertEqual(OCRMatch.choose(["Save As", "Save All"], query: "Save"), .ambiguous([0, 1]))
        XCTAssertEqual(OCRMatch.choose(["File", "Edit"], query: "View"), .none)
    }

    func testOCRTextNotFoundDescriptionRefuses() {
        let e = GhostHandsError.ocrTextNotFound(query: "Login", app: "Foo",
                                                found: ["Sign up", "Help"])
        XCTAssertTrue(e.description.contains("Login"))
        XCTAssertTrue(e.description.lowercased().contains("refus"))
    }
}
