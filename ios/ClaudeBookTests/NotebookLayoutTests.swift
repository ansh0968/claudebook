import XCTest
import UIKit
import PencilKit
@testable import ClaudeBook

final class NotebookLayoutTests: XCTestCase {
    @MainActor
    func testRemoteReorderAndNavigationWaitForTheFinishingStroke() async throws {
        let first = Page.blank(background: .lined)
        let second = Page.blank(background: .grid)
        let originalIds = [first.id, second.id]
        defer { LocalDrawings.remove(originalIds) }
        for id in originalIds { LocalDrawings.save(PKDrawing(), pageId: id) }

        var notebook = Notebook(id: UUID().uuidString, title: "Canvas sync test", pages: [first, second],
                                createdAt: first.updatedAt, updatedAt: first.updatedAt)
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.setNotebook(notebook)
        let library = LibraryModel()
        library.activeCanvas = controller
        library.path = [.notebook(NotebookDestination(notebookId: notebook.id))]
        let lastTarget = NotebookDestination(notebookId: UUID().uuidString, pageId: Page.blank(background: .lined).id)

        controller.canvasViewDidBeginUsingTool(controller.canvas)
        notebook.pages.reverse()
        controller.setNotebook(notebook)
        library.handleCommand(LiveEvent(type: "openPage", notebookId: UUID().uuidString, pageId: first.id))
        library.handleCommand(LiveEvent(type: "openPage", notebookId: lastTarget.notebookId, pageId: lastTarget.pageId))
        XCTAssertEqual(controller.pages.map(\.id), originalIds)
        XCTAssertEqual(library.path, [.notebook(NotebookDestination(notebookId: notebook.id))])

        // Simulate PencilKit publishing its completed drawing after the remote update.
        controller.addTestStroke()
        controller.canvasViewDidEndUsingTool(controller.canvas)
        let reorderedIds = [second.id, first.id]
        for _ in 0..<40 {
            if controller.pages.map(\.id) == reorderedIds { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controller.pages.map(\.id), reorderedIds)
        XCTAssertEqual(library.path, [.notebook(lastTarget)])
        XCTAssertEqual(LocalDrawings.load(first.id)?.strokes.count, 2)
        XCTAssertEqual(LocalDrawings.load(second.id)?.strokes.count, 1)
    }

    @MainActor
    func testConfirmedDeletionStopsLateDrawingSavesAndPendingUploads() {
        let id = "deleted-test-" + UUID().uuidString
        LocalDrawings.save(PKDrawing(), pageId: id)
        PendingUploads.all.insert(id)
        XCTAssertTrue(LocalDrawings.exists(id))
        LocalDrawings.remove([id])
        LocalDrawings.save(PKDrawing(), pageId: id)
        PendingUploads.all.insert(id)
        XCTAssertFalse(LocalDrawings.exists(id))
        XCTAssertNil(LocalDrawings.load(id))
        XCTAssertFalse(PendingUploads.all.contains(id))
    }

    @MainActor
    func testAcknowledgingAnOlderUploadRetainsTheNewInkRevision() throws {
        let id = "revision-test-" + UUID().uuidString
        defer { LocalDrawings.remove([id]) }
        XCTAssertTrue(PendingUploads.mark([id]))
        let first = try XCTUnwrap(PendingUploads.revision(id))
        XCTAssertTrue(PendingUploads.mark([id]))
        let second = try XCTUnwrap(PendingUploads.revision(id))
        XCTAssertNotEqual(first, second)

        PendingUploads.acknowledge(id, revision: first, vectorOnly: false)
        XCTAssertEqual(PendingUploads.revision(id), second)
        PendingUploads.acknowledge(id, revision: second, vectorOnly: true)
        let vectorBackup = try XCTUnwrap(PendingUploads.revision(id))
        XCTAssertEqual(vectorBackup.id, second.id)
        XCTAssertTrue(vectorBackup.vectorBackedUp)
        PendingUploads.acknowledge(id, revision: vectorBackup, vectorOnly: false)
        XCTAssertNil(PendingUploads.revision(id))
    }

    @MainActor
    func testPendingCreationFollowsItsAnchorAndMergesWithoutDuplicatingItsId() throws {
        let anchor = Page.blank(background: .lined)
        let other = Page.blank(background: .grid)
        let draft = Page.blank(background: .blank)
        var notebook = Notebook(id: UUID().uuidString, title: "Pending page", pages: [anchor, other],
                                createdAt: anchor.updatedAt, updatedAt: anchor.updatedAt)
        defer { try? PendingPageCreations.confirm(draft.id, in: notebook.id) }
        try PendingPageCreations.add(.init(page: draft, afterPageId: anchor.id, afterIndex: 0), to: notebook)
        XCTAssertTrue(PendingPageCreations.contains(draft.id))
        XCTAssertEqual(PendingPageCreations.localNotebooks.first { $0.id == notebook.id }?.pages.map(\.id), [draft.id])
        notebook.pages.reverse()
        XCTAssertEqual(PendingPageCreations.merging(into: notebook).pages.map(\.id), [other.id, anchor.id, draft.id])
        notebook.pages.append(draft)
        XCTAssertEqual(PendingPageCreations.merging(into: notebook).pages.count, 3)
        try PendingPageCreations.confirm(draft.id, in: notebook.id)
        XCTAssertFalse(PendingPageCreations.contains(draft.id))
    }

    func testBottomSearchMatchKeepsViewportCenterOnMatchingPage() {
        let region = PageRegion(x: 120, y: 1200, w: 650, h: 45)
        let viewport: CGFloat = 1100
        let inset: CGFloat = 16
        let top = NotebookLayout.centeredTop(for: region, onPage: 0, viewportHeight: viewport, insetTop: inset)
        let viewportCenter = top - inset + viewport / 2
        XCTAssertEqual(viewportCenter, 1222.5, accuracy: 0.01)
        XCTAssertEqual(NotebookLayout.index(forY: viewportCenter, count: 2), 0)
        // Text recognition can return a box extending past the page; keep its center on the page.
        let malformed = PageRegion(x: 10, y: 1400, w: 100, h: 200)
        let clampedTop = NotebookLayout.centeredTop(for: malformed, onPage: 1, viewportHeight: viewport, insetTop: inset)
        XCTAssertEqual(NotebookLayout.index(forY: clampedTop - inset + viewport / 2, count: 3), 1)
    }

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
        overlay.isUserInteractionEnabled = true
        let outside = UIButton(frame: CGRect(x: 190, y: 50, width: 44, height: 44))
        overlay.addSubview(outside)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 210, y: 70), with: nil))
    }

    @MainActor
    func testHintOverlayExposesControlsOutsidePencilKitAndFollowsVisibility() throws {
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        controller.view.layoutIfNeeded()
        let overlay = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? ControlOverlay }.first)
        XCTAssertTrue(overlay.superview === controller.view)
        XCTAssertFalse(overlay.isDescendant(of: controller.canvas))
        let chip = UIButton(frame: CGRect(x: 50, y: 50, width: 44, height: 44))
        chip.isAccessibilityElement = true
        overlay.addSubview(chip)
        overlay.refreshAccessibilityElements()
        XCTAssertFalse(overlay.isAccessibilityElement)
        XCTAssertTrue(overlay.accessibilityElements?.first as? UIButton === chip)
        controller.showClaude = false
        XCTAssertTrue(overlay.isHidden)
        XCTAssertTrue(overlay.accessibilityElements?.isEmpty == true)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 70, y: 70), with: nil))
        controller.showClaude = true
        XCTAssertTrue(overlay.accessibilityElements?.first as? UIButton === chip)
        XCTAssertTrue(overlay.hitTest(CGPoint(x: 70, y: 70), with: nil) === chip)
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
