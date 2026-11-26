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

    private static func testStroke(at origin: CGPoint) -> PKStroke {
        let points = [origin, CGPoint(x: origin.x + 80, y: origin.y + 24)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 5, height: 5),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .systemBlue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    @MainActor
    private static func applyUndoableDrawing(_ next: PKDrawing, to canvas: PKCanvasView) {
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in
            MainActor.assumeIsolated {
                Self.applyUndoableDrawing(previous, to: target)
            }
        }
        canvas.drawing = next
    }

    @MainActor
    private func recordUndoableStroke(at origin: CGPoint, on canvas: PKCanvasView) {
        let stroke = Self.testStroke(at: origin)
        Self.applyUndoableDrawing(PKDrawing(strokes: canvas.drawing.strokes + [stroke]), to: canvas)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    @MainActor
    func testDedicatedUndoManagerWorksWithoutWindowAndStaysIsolatedFromRoughCanvas() async throws {
        let page = Page.blank(background: .lined)
        let added = Page.blank(background: .lined)
        defer { LocalDrawings.remove([page.id, added.id]) }
        for id in [page.id, added.id] { LocalDrawings.save(PKDrawing(), pageId: id) }

        var notebook = Notebook(id: UUID().uuidString, title: "Undo isolation", pages: [page],
                                createdAt: page.updatedAt, updatedAt: page.updatedAt)
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        await controller.pauseUploads()
        XCTAssertNil(controller.view.window)
        let notebookUndo = try XCTUnwrap(controller.canvas.undoManager)
        XCTAssertTrue(notebookUndo === controller.undoManager)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        container.addSubview(controller.view)
        let roughHost = RoughCanvasHost(controller: controller)
        container.addSubview(roughHost)
        defer {
            roughHost.detach()
            container.removeFromSuperview()
        }

        let roughUndo = try XCTUnwrap(roughHost.canvas.undoManager)
        XCTAssertFalse(roughUndo === notebookUndo)

        controller.setNotebook(notebook)
        recordUndoableStroke(at: CGPoint(x: 120, y: 200), on: controller.canvas)
        roughHost.show(RoughSheet())
        recordUndoableStroke(at: CGPoint(x: 80, y: 120), on: roughHost.canvas)
        XCTAssertTrue(notebookUndo.canUndo)
        XCTAssertTrue(roughUndo.canUndo)

        // Switching rough sheets clears the rough canvas undo stack without touching the notebook's.
        roughHost.show(RoughSheet())
        XCTAssertFalse(roughUndo.canUndo)
        XCTAssertTrue(notebookUndo.canUndo)

        // Rebuilding the notebook canvas clears the notebook undo stack without touching rough work.
        recordUndoableStroke(at: CGPoint(x: 80, y: 180), on: roughHost.canvas)
        XCTAssertTrue(roughUndo.canUndo)
        notebook.pages.append(added)
        controller.setNotebook(notebook)
        XCTAssertFalse(notebookUndo.canUndo)
        XCTAssertTrue(roughUndo.canUndo)
    }

    @MainActor
    func testPageEditsAndNonEmptyBackupsClearUndoAndRedoWhileSameLayoutRefreshesKeepThem() async throws {
        let first = Page.blank(background: .lined)
        let emptyBackup = Page.blank(background: .grid)
        let inkBackup = Page.blank(background: .dotted)
        let inserted = Page.blank(background: .blank)
        let allIds = [first.id, emptyBackup.id, inkBackup.id, inserted.id]
        defer { LocalDrawings.remove(allIds) }
        for id in allIds { LocalDrawings.save(PKDrawing(), pageId: id) }

        let emptyPageId = emptyBackup.id
        let inkPageId = inkBackup.id
        let emptyData = PKDrawing().dataRepresentation()
        let inkData = PKDrawing(strokes: [Self.testStroke(at: CGPoint(x: 240, y: 320))]).dataRepresentation()

        var notebook = Notebook(id: UUID().uuidString, title: "Undo rebuild test", pages: [first, emptyBackup, inkBackup],
                                createdAt: first.updatedAt, updatedAt: first.updatedAt)
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        await controller.pauseUploads()
        controller.backupDrawingLoader = { id in
            if id == emptyPageId { return emptyData }
            if id == inkPageId { return inkData }
            return nil
        }
        let undo = try XCTUnwrap(controller.canvas.undoManager)
        controller.setNotebook(notebook)

        recordUndoableStroke(at: CGPoint(x: 160, y: 220), on: controller.canvas)
        recordUndoableStroke(at: CGPoint(x: 160, y: 420), on: controller.canvas)
        undo.undo()
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)
        XCTAssertTrue(undo.canUndo)
        XCTAssertTrue(undo.canRedo)

        // Same-layout refreshes (paper and Claude layer updates) keep undo and redo intact.
        notebook.pages[0].paper = .cream
        let claudeItem = try JSONDecoder().decode(ClaudeItem.self, from: Data(#"{"id":"note","type":"text","x":100,"y":100,"text":"ok"}"#.utf8))
        notebook.pages[0].claudeLayer = [claudeItem]
        controller.setNotebook(notebook)
        XCTAssertTrue(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 2)
        undo.undo()
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)
        XCTAssertTrue(undo.canUndo)
        XCTAssertTrue(undo.canRedo)

        // Downloading an empty backup does not rebuild the canvas, so undo and redo stay intact.
        try FileManager.default.removeItem(at: LocalDrawings.url(emptyBackup.id))
        XCTAssertFalse(LocalDrawings.exists(emptyBackup.id))
        controller.setNotebook(notebook)
        for _ in 0..<40 {
            if LocalDrawings.exists(emptyBackup.id) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(LocalDrawings.exists(emptyBackup.id))
        XCTAssertEqual(LocalDrawings.load(emptyBackup.id)?.strokes.count, 0)
        XCTAssertTrue(undo.canUndo)
        XCTAssertTrue(undo.canRedo)

        // Downloading a non-empty backup rebuilds the canvas and clears both undo and redo.
        try FileManager.default.removeItem(at: LocalDrawings.url(inkBackup.id))
        XCTAssertFalse(LocalDrawings.exists(inkBackup.id))
        controller.setNotebook(notebook)
        for _ in 0..<40 {
            if LocalDrawings.load(inkBackup.id)?.strokes.count == 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(LocalDrawings.load(inkBackup.id)?.strokes.count, 1)
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 2)
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        await controller.pauseUploads()
        XCTAssertEqual(LocalDrawings.load(first.id)?.strokes.count, 1)
        XCTAssertEqual(LocalDrawings.load(inkBackup.id)?.strokes.count, 1)

        // Inserting or reordering pages clears undo and redo so shifted pages keep their ink.
        recordUndoableStroke(at: CGPoint(x: 160, y: 620), on: controller.canvas)
        recordUndoableStroke(at: CGPoint(x: 160, y: 820), on: controller.canvas)
        undo.undo()
        XCTAssertTrue(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        notebook.pages.insert(inserted, at: 0)
        controller.setNotebook(notebook)
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        await controller.pauseUploads()
        XCTAssertEqual(LocalDrawings.load(inserted.id)?.strokes.count, 0)
        XCTAssertEqual(LocalDrawings.load(first.id)?.strokes.count, 2)
        XCTAssertEqual(LocalDrawings.load(inkBackup.id)?.strokes.count, 1)

        // Deleting pages also rebuilds the canvas and clears undo and redo.
        recordUndoableStroke(at: CGPoint(x: 180, y: 200), on: controller.canvas)
        recordUndoableStroke(at: CGPoint(x: 180, y: 360), on: controller.canvas)
        undo.undo()
        XCTAssertTrue(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        controller.discardPages([inserted.id])
        notebook.pages.removeAll { $0.id == inserted.id }
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        await controller.pauseUploads()
        XCTAssertEqual(LocalDrawings.load(first.id)?.strokes.count, 2)
        XCTAssertEqual(LocalDrawings.load(inkBackup.id)?.strokes.count, 1)

        // A layout edit deferred during active drawing commits the stroke first, then clears undo on rebuild.
        controller.canvasViewDidBeginUsingTool(controller.canvas)
        notebook.pages.reverse()
        controller.setNotebook(notebook)
        recordUndoableStroke(at: CGPoint(x: 160, y: 980), on: controller.canvas)
        XCTAssertTrue(undo.canUndo)
        controller.canvasViewDidEndUsingTool(controller.canvas)
        let reversedIds = notebook.pages.map(\.id)
        for _ in 0..<40 {
            if controller.pages.map(\.id) == reversedIds { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controller.pages.map(\.id), reversedIds)
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        XCTAssertEqual(LocalDrawings.load(first.id)?.strokes.count, 3)
        XCTAssertEqual(LocalDrawings.load(inkBackup.id)?.strokes.count, 1)
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

    @MainActor
    func testAuthoritativeDeletionDropsOnlyInactiveBlankPendingPages() throws {
        let blank = Page.blank(background: .grid)
        let active = Page.blank(background: .grid)
        let queued = Page.blank(background: .grid)
        let drawn = Page.blank(background: .grid)
        let ids = [blank.id, active.id, queued.id, drawn.id]
        let notebook = Notebook(id: UUID().uuidString, title: "Drafts", pages: [],
                                createdAt: blank.updatedAt, updatedAt: blank.updatedAt)
        defer {
            for id in ids { try? PendingPageCreations.confirm(id, in: notebook.id) }
            LocalDrawings.remove(ids)
        }
        for page in [blank, active, queued, drawn] {
            try PendingPageCreations.add(.init(page: page, afterPageId: nil, afterIndex: 0), to: notebook)
        }
        XCTAssertTrue(PendingUploads.mark([queued.id]))
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 5, height: 5),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .systemBlue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        XCTAssertTrue(LocalDrawings.save(PKDrawing(strokes: [stroke]), pageId: drawn.id))

        try PendingPageCreations.pruneDeletedBlankPages(ids, activePageIds: [active.id])
        XCTAssertFalse(PendingPageCreations.contains(blank.id))
        XCTAssertTrue(PendingPageCreations.contains(active.id))
        XCTAssertTrue(PendingPageCreations.contains(queued.id))
        XCTAssertTrue(PendingPageCreations.contains(drawn.id))
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
