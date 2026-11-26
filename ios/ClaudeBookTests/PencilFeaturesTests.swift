import CoreGraphics
import PencilKit
import UIKit
import XCTest
@testable import ClaudeBook

@MainActor
final class PencilFeaturesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PencilSettings.doubleTapUndoKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PencilSettings.doubleTapUndoKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private func polyline(_ vertices: [CGPoint], closed: Bool = false, stepsPerSegment: Int = 24) -> [CGPoint] {
        guard let first = vertices.first else { return [] }
        let path = closed ? vertices + [first] : vertices
        var out: [CGPoint] = []
        for (a, b) in zip(path, path.dropFirst()) {
            for step in 0..<stepsPerSegment {
                out.append(a + (b - a) * (CGFloat(step) / CGFloat(stepsPerSegment)))
            }
        }
        out.append(path[path.count - 1])
        return out
    }

    private func jitter(_ points: [CGPoint], amount: CGFloat = 1.2, seed: UInt64 = 1) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func noise() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(Double(state >> 11) / Double(1 << 53)) * 2 - 1
        }
        var ox: CGFloat = 0
        var oy: CGFloat = 0
        return points.map { p in
            ox = 0.75 * ox + amount * noise()
            oy = 0.75 * oy + amount * noise()
            return CGPoint(x: p.x + ox, y: p.y + oy)
        }
    }

    private func makeStroke(
        _ points: [CGPoint],
        color: UIColor = .black,
        width: CGFloat = 4,
        transform: CGAffineTransform = .identity
    ) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.008,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: color),
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()),
            transform: transform,
            mask: nil
        )
    }

    private func horizontalScribble(at origin: CGPoint, width: CGFloat = 180, stepY: CGFloat = 6) -> PKStroke {
        let verts = [
            CGPoint(x: origin.x, y: origin.y),
            CGPoint(x: origin.x + width, y: origin.y + stepY),
            CGPoint(x: origin.x + 8, y: origin.y + stepY * 2),
            CGPoint(x: origin.x + width - 6, y: origin.y + stepY * 3),
            CGPoint(x: origin.x + 12, y: origin.y + stepY * 4),
        ]
        return makeStroke(jitter(polyline(verts)))
    }

    // MARK: - 1. Scribble Detection

    func testScribbleDetectionRecognizesScratchOutsAndSawtoothZigzags() {
        // Collinear 4-leg and 5-leg horizontal scratch-outs
        let collinear4 = polyline([
            CGPoint(x: 100, y: 200),
            CGPoint(x: 300, y: 200),
            CGPoint(x: 100, y: 200),
            CGPoint(x: 300, y: 200),
            CGPoint(x: 100, y: 200),
        ])
        XCTAssertTrue(ScribbleEraser.isScribble(collinear4))

        let collinear5 = polyline([
            CGPoint(x: 100, y: 200),
            CGPoint(x: 300, y: 200),
            CGPoint(x: 100, y: 200),
            CGPoint(x: 300, y: 200),
            CGPoint(x: 100, y: 200),
            CGPoint(x: 300, y: 200),
        ])
        XCTAssertTrue(ScribbleEraser.isScribble(collinear5))

        // Horizontal drifted back-and-forth scratch-out with hand jitter
        let horizDrifted = jitter(polyline([
            CGPoint(x: 100, y: 200),
            CGPoint(x: 290, y: 206),
            CGPoint(x: 108, y: 214),
            CGPoint(x: 285, y: 222),
            CGPoint(x: 112, y: 230),
        ]))
        XCTAssertTrue(ScribbleEraser.isScribble(horizDrifted))

        // Vertical back-and-forth scratch-out
        let vertScratch = jitter(polyline([
            CGPoint(x: 200, y: 100),
            CGPoint(x: 206, y: 280),
            CGPoint(x: 214, y: 108),
            CGPoint(x: 222, y: 276),
            CGPoint(x: 230, y: 112),
        ]))
        XCTAssertTrue(ScribbleEraser.isScribble(vertScratch))

        // Diagonal back-and-forth scratch-out
        let diagScratch = jitter(polyline([
            CGPoint(x: 100, y: 100),
            CGPoint(x: 260, y: 260),
            CGPoint(x: 110, y: 122),
            CGPoint(x: 268, y: 280),
            CGPoint(x: 120, y: 140),
        ]))
        XCTAssertTrue(ScribbleEraser.isScribble(diagScratch))

        // Steep sawtooth zigzag and 90-degree sawtooth zigzag
        let steepZigzag = jitter(polyline([
            CGPoint(x: 100, y: 220),
            CGPoint(x: 132, y: 130),
            CGPoint(x: 164, y: 220),
            CGPoint(x: 196, y: 130),
            CGPoint(x: 228, y: 220),
        ]))
        XCTAssertTrue(ScribbleEraser.isScribble(steepZigzag))

        let rightAngleZigzag = jitter(polyline([
            CGPoint(x: 100, y: 200),
            CGPoint(x: 145, y: 155),
            CGPoint(x: 190, y: 200),
            CGPoint(x: 235, y: 155),
            CGPoint(x: 280, y: 200),
        ]))
        XCTAssertTrue(ScribbleEraser.isScribble(rightAngleZigzag))

        // Rounded U-turn continuous scribble
        let roundedScribble = (0...200).map { i -> CGPoint in
            let t = CGFloat(i) / 200 * 4 * .pi
            return CGPoint(x: 220 + 95 * cos(t), y: 200 + CGFloat(i) * 0.25)
        }
        XCTAssertTrue(ScribbleEraser.isScribble(jitter(roundedScribble)))
    }

    func testScribbleDetectionRejectsLinesCornersShapesArrowsAndDots() {
        // Straight strikethrough line
        let straightLine = jitter(polyline([CGPoint(x: 100, y: 200), CGPoint(x: 420, y: 202)]))
        XCTAssertFalse(ScribbleEraser.isScribble(straightLine))

        // Checkmark and single right-angle corner
        let checkmark = jitter(polyline([CGPoint(x: 100, y: 210), CGPoint(x: 132, y: 248), CGPoint(x: 230, y: 140)]))
        XCTAssertFalse(ScribbleEraser.isScribble(checkmark))

        let corner = jitter(polyline([CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 300)]))
        XCTAssertFalse(ScribbleEraser.isScribble(corner))

        // 3-leg Z stroke
        let zShape = jitter(polyline([
            CGPoint(x: 100, y: 100),
            CGPoint(x: 250, y: 100),
            CGPoint(x: 100, y: 250),
            CGPoint(x: 250, y: 250),
        ]))
        XCTAssertFalse(ScribbleEraser.isScribble(zShape))

        // Closed shapes: circle, rectangle, square, triangle
        let circle = jitter((0...104).map { i in
            let t = CGFloat(i) / 100 * 2 * .pi
            return CGPoint(x: 250 + 110 * cos(t), y: 250 + 110 * sin(t))
        })
        XCTAssertFalse(ScribbleEraser.isScribble(circle))

        let rectangle = jitter(polyline([
            CGPoint(x: 100, y: 100),
            CGPoint(x: 340, y: 100),
            CGPoint(x: 340, y: 260),
            CGPoint(x: 100, y: 260),
        ], closed: true))
        XCTAssertFalse(ScribbleEraser.isScribble(rectangle))

        let triangle = jitter(polyline([
            CGPoint(x: 100, y: 300),
            CGPoint(x: 220, y: 110),
            CGPoint(x: 340, y: 300),
        ], closed: true))
        XCTAssertFalse(ScribbleEraser.isScribble(triangle))

        // Single-stroke arrow with full two-barb head
        let arrow = jitter(polyline([
            CGPoint(x: 100, y: 200),
            CGPoint(x: 420, y: 200),
            CGPoint(x: 384, y: 180),
            CGPoint(x: 420, y: 200),
            CGPoint(x: 384, y: 220),
        ]))
        XCTAssertFalse(ScribbleEraser.isScribble(arrow))

        // Tiny dot and micro-tremor
        let dot = [CGPoint(x: 150, y: 150), CGPoint(x: 151, y: 151), CGPoint(x: 150, y: 152), CGPoint(x: 150, y: 150)]
        XCTAssertFalse(ScribbleEraser.isScribble(dot))
    }

    // MARK: - 2. Stroke Intersection & Removal

    func testStrokeIntersectionRemovesTouchedSubsetAndPreservesEmptySpaceScribbles() {
        let page = Page.blank(background: .lined)
        defer { LocalDrawings.remove([page.id]) }
        LocalDrawings.save(PKDrawing(), pageId: page.id)

        let notebook = Notebook(
            id: UUID().uuidString,
            title: "Scribble subset test",
            pages: [page],
            createdAt: page.updatedAt,
            updatedAt: page.updatedAt
        )
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.setNotebook(notebook)

        // Scribbling on empty paper keeps the stroke intact.
        let emptyScribble = horizontalScribble(at: CGPoint(x: 120, y: 120))
        controller.applyUserStroke(emptyScribble)
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)

        // Reset canvas and draw three separate horizontal lines; scribble over the first two only.
        controller.canvas.drawing = PKDrawing()
        let line1 = makeStroke(polyline([CGPoint(x: 100, y: 300), CGPoint(x: 320, y: 300)]))
        let line2 = makeStroke(polyline([CGPoint(x: 100, y: 318), CGPoint(x: 320, y: 318)]))
        let untouchedLine = makeStroke(polyline([CGPoint(x: 100, y: 760), CGPoint(x: 380, y: 760)]))
        controller.applyUserStroke(line1)
        controller.applyUserStroke(line2)
        controller.applyUserStroke(untouchedLine)
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 3)

        let eraseScribble = horizontalScribble(at: CGPoint(x: 110, y: 294), width: 200, stepY: 7)
        controller.applyUserStroke(eraseScribble)

        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1, "Both touched lines and the scribble should be removed")
        XCTAssertEqual(controller.canvas.drawing.strokes[0].renderBounds.midY, untouchedLine.renderBounds.midY, accuracy: 2)

        // Programmatic canvas.drawing assignment must not trigger ScribbleEraser.
        let programmaticScribble = horizontalScribble(at: CGPoint(x: 110, y: 752), width: 220, stepY: 5)
        controller.canvas.drawing = PKDrawing(strokes: controller.canvas.drawing.strokes + [programmaticScribble])
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 2)

        // Strokes snapped/held by ShapeSnapper (editingShape != nil) suppress ScribbleEraser.
        let zigzagVerts = [
            CGPoint(x: 100, y: 760),
            CGPoint(x: 145, y: 715),
            CGPoint(x: 190, y: 760),
            CGPoint(x: 235, y: 715),
            CGPoint(x: 280, y: 760),
        ]
        controller.shapes.snapForTesting(polyline(zigzagVerts, stepsPerSegment: 16))
        XCTAssertNotNil(controller.shapes.editingShape)
        XCTAssertEqual(controller.scribbleEraser.shouldSuppress?(), true)
        let countWithSnappedShape = controller.canvas.drawing.strokes.count
        controller.applyUserStroke(horizontalScribble(at: CGPoint(x: 110, y: 745), width: 180, stepY: 5))
        XCTAssertEqual(controller.canvas.drawing.strokes.count, countWithSnappedShape + 1)
        controller.shapes.endEditing()
    }

    func testScribbleEraseIntersectsTransformedStrokesOnLaterNotebookPages() {
        let page1 = Page.blank(background: .lined)
        let page2 = Page.blank(background: .grid)
        let ids = [page1.id, page2.id]
        defer { LocalDrawings.remove(ids) }

        let p1Stroke = makeStroke(polyline([CGPoint(x: 120, y: 250), CGPoint(x: 360, y: 250)]))
        let p2EraseTarget = makeStroke(polyline([CGPoint(x: 140, y: 250), CGPoint(x: 380, y: 250)]))
        let p2KeepStroke = makeStroke(polyline([CGPoint(x: 140, y: 650), CGPoint(x: 380, y: 650)]))
        LocalDrawings.save(PKDrawing(strokes: [p1Stroke]), pageId: page1.id)
        LocalDrawings.save(PKDrawing(strokes: [p2EraseTarget, p2KeepStroke]), pageId: page2.id)

        let notebook = Notebook(
            id: UUID().uuidString,
            title: "Multi-page scribble",
            pages: [page1, page2],
            createdAt: page1.updatedAt,
            updatedAt: page1.updatedAt
        )
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.setNotebook(notebook)
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 3)

        // Verify page 2 strokes carry non-identity vertical translation in PKStroke.transform.
        let page2Offset = NotebookLayout.offset(1)
        let transformedStrokes = controller.canvas.drawing.strokes.filter { abs($0.transform.ty - page2Offset) < 1 }
        XCTAssertEqual(transformedStrokes.count, 2)

        // Draw a scribble in page 2's canvas coordinate space over p2EraseTarget (leaving p1Stroke at local y=250 untouched!).
        let page2Scribble = horizontalScribble(at: CGPoint(x: 150, y: page2Offset + 242), width: 210, stepY: 6)
        controller.applyUserStroke(page2Scribble)
        controller.flush()

        XCTAssertEqual(controller.canvas.drawing.strokes.count, 2)
        XCTAssertEqual(LocalDrawings.load(page1.id)?.strokes.count, 1, "Page 1 stroke at same local y must remain untouched")
        XCTAssertEqual(LocalDrawings.load(page2.id)?.strokes.count, 1, "Only the intersected Page 2 stroke should be erased")
        let remainingPage2Y = LocalDrawings.load(page2.id)?.strokes.first?.renderBounds.midY ?? 0
        XCTAssertEqual(remainingPage2Y, 650, accuracy: 3)
    }

    // MARK: - 3. Undo & Redo Restoration Across All Canvases

    func testScribbleUndoAndRedoRestorePersistedInkOnNotebookCanvasController() {
        let page = Page.blank(background: .lined)
        defer { LocalDrawings.remove([page.id]) }
        LocalDrawings.save(PKDrawing(), pageId: page.id)

        let notebook = Notebook(
            id: UUID().uuidString,
            title: "Notebook undo redo",
            pages: [page],
            createdAt: page.updatedAt,
            updatedAt: page.updatedAt
        )
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.setNotebook(notebook)

        XCTAssertNotNil(controller.canvas.undoManager)
        XCTAssertFalse(controller.canvas.undoManager?.canUndo ?? true, "rebuildCanvasDrawing should start with clean undo stack")

        let erasedLine = makeStroke(polyline([CGPoint(x: 120, y: 300), CGPoint(x: 380, y: 300)]))
        let keptLine = makeStroke(polyline([CGPoint(x: 120, y: 600), CGPoint(x: 380, y: 600)]))
        controller.applyUserStroke(erasedLine)
        controller.applyUserStroke(keptLine)
        controller.flush()
        XCTAssertEqual(LocalDrawings.load(page.id)?.strokes.count, 2)

        // Scribble over erasedLine
        let scribble = horizontalScribble(at: CGPoint(x: 130, y: 290), width: 220, stepY: 6)
        controller.applyUserStroke(scribble)
        controller.flush()
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(LocalDrawings.load(page.id)?.strokes.count, 1)

        // Single undo restores pre-scribble drawing (both lines back, scribble itself absent)
        controller.canvas.undoManager?.undo()
        controller.flush()
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 2)
        XCTAssertEqual(LocalDrawings.load(page.id)?.strokes.count, 2)
        XCTAssertFalse(controller.canvas.drawing.strokes.contains { ScribbleEraser.isScribble($0) })

        // Redo re-applies the scribble erasure
        controller.canvas.undoManager?.redo()
        controller.flush()
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(LocalDrawings.load(page.id)?.strokes.count, 1)
    }

    func testScribbleUndoAndRedoRestorePersistedInkOnRoughCanvasHostWithIsolatedUndoManager() {
        let pageId = "rough-test-" + UUID().uuidString
        defer { RoughStore.remove([pageId]) }

        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()

        let roughModel = RoughModel()
        roughModel.show(pageId: pageId)

        let host = RoughCanvasHost(controller: controller)
        host.onChange = { drawing, sheetId in
            roughModel.setInk(drawing, sheetId: sheetId)
        }
        host.show(roughModel.current)

        // Dedicated isolated UndoManagers even without a UIWindow
        XCTAssertNotNil(host.canvas.undoManager)
        XCTAssertNotNil(controller.canvas.undoManager)
        XCTAssertTrue(host.canvas.undoManager !== controller.canvas.undoManager)

        let strokeA = makeStroke(polyline([CGPoint(x: 60, y: 220), CGPoint(x: 340, y: 220)]))
        let strokeB = makeStroke(polyline([CGPoint(x: 60, y: 520), CGPoint(x: 340, y: 520)]))
        host.applyUserStroke(strokeA)
        host.applyUserStroke(strokeB)
        XCTAssertEqual(host.canvas.drawing.strokes.count, 2)
        XCTAssertEqual(roughModel.current.strokes, 2)

        // Scribble over strokeA
        let scribble = horizontalScribble(at: CGPoint(x: 70, y: 210), width: 240, stepY: 6)
        host.applyUserStroke(scribble)
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(roughModel.current.strokes, 1)

        // Undo restores both strokes (without the scribble) and updates RoughModel
        host.canvas.undoManager?.undo()
        XCTAssertEqual(host.canvas.drawing.strokes.count, 2)
        XCTAssertEqual(roughModel.current.strokes, 2)
        roughModel.flush()
        XCTAssertEqual(RoughStore.load(pageId).first?.strokes, 2)

        // Redo removes strokeA again and updates RoughModel
        host.canvas.undoManager?.redo()
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(roughModel.current.strokes, 1)
        roughModel.flush()
        XCTAssertEqual(RoughStore.load(pageId).first?.strokes, 1)

        // Switching rough sheets resets RoughCanvasHost's undo stack cleanly
        roughModel.addSheet()
        host.show(roughModel.current)
        XCTAssertFalse(host.canvas.undoManager?.canUndo ?? true)
    }

    // MARK: - 4. Apple Pencil Double-Tap Undo & Settings Toggle

    func testApplePencilDoubleTapTriggersUndoWithoutSwitchingToolAcrossCanvases() async throws {
        let page = Page.blank(background: .lined)
        defer { LocalDrawings.remove([page.id]) }
        LocalDrawings.save(PKDrawing(), pageId: page.id)

        let notebook = Notebook(
            id: UUID().uuidString,
            title: "Double tap undo",
            pages: [page],
            createdAt: page.updatedAt,
            updatedAt: page.updatedAt
        )
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.setNotebook(notebook)

        let host = RoughCanvasHost(controller: controller)
        host.show(RoughSheet())

        XCTAssertTrue(PencilSettings.isDoubleTapUndoEnabled)
        XCTAssertTrue(controller.pencilDoubleTap.interaction.isEnabled)
        XCTAssertTrue(host.pencilDoubleTap.interaction.isEnabled)

        // Select marker tool intentionally via PKToolPicker
        let marker = PKInkingTool(.marker, color: .systemRed, width: 10)
        controller.toolPicker.selectedTool = marker
        controller.toolPickerSelectedToolDidChange(controller.toolPicker)
        XCTAssertEqual((controller.canvas.tool as? PKInkingTool)?.inkType, .marker)

        // Draw two strokes on main notebook canvas (locks in marker as active tool)
        let s1 = makeStroke(polyline([CGPoint(x: 100, y: 200), CGPoint(x: 320, y: 200)]))
        let s2 = makeStroke(polyline([CGPoint(x: 100, y: 340), CGPoint(x: 320, y: 340)]))
        controller.applyUserStroke(s1)
        controller.applyUserStroke(s2)
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 2)

        // Case A: PKToolPicker switches to eraser immediately BEFORE pencilInteractionDidTap fires
        let eraser = PKEraserTool(.vector)
        controller.toolPicker.selectedTool = eraser
        controller.toolPickerSelectedToolDidChange(controller.toolPicker)
        controller.pencilDoubleTap.pencilInteractionDidTap(controller.pencilDoubleTap.interaction)

        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1, "Double-tap should undo the second stroke")
        XCTAssertEqual((controller.toolPicker.selectedTool as? PKInkingTool)?.inkType, .marker)
        XCTAssertEqual((controller.canvas.tool as? PKInkingTool)?.inkType, .marker)

        // Case B: pencilInteractionDidTap fires FIRST, then PKToolPicker tries to switch to eraser within 80ms
        controller.applyUserStroke(s2)
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 2)
        controller.pencilDoubleTap.pencilInteractionDidTap(controller.pencilDoubleTap.interaction)
        controller.toolPicker.selectedTool = eraser
        controller.toolPickerSelectedToolDidChange(controller.toolPicker)

        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)
        XCTAssertEqual((controller.toolPicker.selectedTool as? PKInkingTool)?.inkType, .marker)
        XCTAssertEqual((controller.canvas.tool as? PKInkingTool)?.inkType, .marker)

        // Case C: RoughCanvasHost active — double-tap on either interaction undoes rough canvas, not main canvas
        controller.roughCanvas = host.canvas
        host.applyUserStroke(makeStroke(polyline([CGPoint(x: 50, y: 120), CGPoint(x: 260, y: 120)])))
        host.applyUserStroke(makeStroke(polyline([CGPoint(x: 50, y: 220), CGPoint(x: 260, y: 220)])))
        XCTAssertEqual(host.canvas.drawing.strokes.count, 2)

        host.pencilDoubleTap.pencilInteractionDidTap(host.pencilDoubleTap.interaction)
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1, "Rough canvas should undo its second stroke")
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1, "Main notebook canvas must remain untouched")
        XCTAssertEqual((host.canvas.tool as? PKInkingTool)?.inkType, .marker)

        controller.pencilDoubleTap.pencilInteractionDidTap(controller.pencilDoubleTap.interaction)
        XCTAssertEqual(host.canvas.drawing.strokes.count, 0, "Controller double-tap should also target active roughCanvas")
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1, "Main notebook canvas still untouched")

        // Case D: Normal user selection on PKToolPicker outside the ~80ms window changes tools freely
        try await Task.sleep(for: .milliseconds(110))
        controller.toolPicker.selectedTool = eraser
        controller.toolPickerSelectedToolDidChange(controller.toolPicker)
        XCTAssertTrue(controller.canvas.tool is PKEraserTool)
        XCTAssertTrue(host.canvas.tool is PKEraserTool)
    }

    func testDisablingPencilDoubleTapUndoDisablesInteractionAndPreservesToolPickerBehavior() {
        let page = Page.blank(background: .lined)
        defer { LocalDrawings.remove([page.id]) }
        LocalDrawings.save(PKDrawing(), pageId: page.id)

        let notebook = Notebook(
            id: UUID().uuidString,
            title: "Disabled double tap",
            pages: [page],
            createdAt: page.updatedAt,
            updatedAt: page.updatedAt
        )
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.setNotebook(notebook)

        let host = RoughCanvasHost(controller: controller)
        host.show(RoughSheet())
        controller.roughCanvas = host.canvas

        // Disable via persisted setting (as toggled in Settings UI)
        PencilSettings.isDoubleTapUndoEnabled = false
        XCTAssertFalse(controller.pencilDoubleTapUndo)
        XCTAssertFalse(controller.pencilDoubleTap.interaction.isEnabled)
        XCTAssertFalse(host.pencilDoubleTap.interaction.isEnabled)

        controller.applyUserStroke(makeStroke(polyline([CGPoint(x: 100, y: 200), CGPoint(x: 320, y: 200)])))
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)

        // Tapping interaction while disabled is a no-op
        controller.pencilDoubleTap.pencilInteractionDidTap(controller.pencilDoubleTap.interaction)
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)

        // PKToolPicker switching to eraser is preserved untouched
        let eraser = PKEraserTool(.vector)
        controller.toolPicker.selectedTool = eraser
        controller.toolPickerSelectedToolDidChange(controller.toolPicker)
        XCTAssertTrue(controller.canvas.tool is PKEraserTool)
        XCTAssertTrue(host.canvas.tool is PKEraserTool)

        // Re-enabling updates both canvases immediately
        controller.pencilDoubleTapUndo = true
        XCTAssertTrue(PencilSettings.isDoubleTapUndoEnabled)
        XCTAssertTrue(controller.pencilDoubleTap.interaction.isEnabled)
        XCTAssertTrue(host.pencilDoubleTap.interaction.isEnabled)
    }
}
