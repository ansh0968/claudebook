import XCTest
import UIKit
@testable import ClaudeBook

final class NotebookLayoutTests: XCTestCase {
    func testSelectionUsesPageCoordinatesAfterScroll() throws {
        let top = NotebookLayout.offset(2)
        let (index, region) = try XCTUnwrap(NotebookLayout.region(
            from: CGPoint(x: 120, y: top + 200), to: CGPoint(x: 380, y: top + 460), count: 4))
        XCTAssertEqual(index, 2)
        XCTAssertEqual(region, PageRegion(x: 120, y: 200, w: 260, h: 260))
    }

    func testReverseDragAndCrossPageClippingKeepStartingPage() throws {
        let top = NotebookLayout.offset(1)
        let (index, region) = try XCTUnwrap(NotebookLayout.region(
            from: CGPoint(x: 900, y: top + 100), to: CGPoint(x: -50, y: top - 100), count: 3))
        XCTAssertEqual(index, 1)
        XCTAssertEqual(region, PageRegion(x: 0, y: 0, w: 900, h: 100))
        let (_, bottom) = try XCTUnwrap(NotebookLayout.region(
            from: CGPoint(x: 900, y: 1300), to: CGPoint(x: 1200, y: 1700), count: 3))
        XCTAssertEqual(bottom, PageRegion(x: 900, y: 1300, w: 100, h: 114))
    }

    func testGapOutsideEmptyNotebookAndTinySelectionsAreRejected() {
        XCTAssertNil(NotebookLayout.region(from: CGPoint(x: 100, y: 1420), to: CGPoint(x: 400, y: 1600), count: 3))
        XCTAssertNil(NotebookLayout.region(from: CGPoint(x: 100, y: -20), to: CGPoint(x: 400, y: 200), count: 3))
        XCTAssertNil(NotebookLayout.region(from: CGPoint(x: 1001, y: 100), to: CGPoint(x: 400, y: 200), count: 3))
        XCTAssertNil(NotebookLayout.region(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 200), count: 0))
        XCTAssertNil(NotebookLayout.region(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 200), count: 3))
    }

    @MainActor
    func testHiddenControlsNeverInterceptPencilKitTouches() {
        let overlay = ControlOverlay(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let chip = UIButton(frame: CGRect(x: 50, y: 50, width: 44, height: 44))
        overlay.addSubview(chip)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 10, y: 10), with: nil))
        XCTAssertTrue(overlay.hitTest(CGPoint(x: 70, y: 70), with: nil) === chip)
        overlay.isHidden = true
        XCTAssertNil(overlay.hitTest(CGPoint(x: 70, y: 70), with: nil))
        overlay.isHidden = false
        overlay.isUserInteractionEnabled = false
        XCTAssertNil(overlay.hitTest(CGPoint(x: 70, y: 70), with: nil))
    }

    func testNewItemWireFieldsDecodeWithoutChangingNames() throws {
        let data = Data(#"{"id":"arrow","type":"curved_arrow","half_head":true,"bend":-40,"group":"mechanism"}"#.utf8)
        let item = try JSONDecoder().decode(ClaudeItem.self, from: data)
        XCTAssertEqual(item.halfHead, true)
        XCTAssertEqual(item.bend, -40)
        XCTAssertEqual(item.group, "mechanism")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        XCTAssertEqual(encoded["half_head"] as? Bool, true)
        XCTAssertNil(encoded["halfHead"])
    }
}
