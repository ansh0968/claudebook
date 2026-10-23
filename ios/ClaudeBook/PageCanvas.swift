import PencilKit
import SwiftUI
import UIKit

/// One page. PKCanvasView is itself the zooming scroll view, so PencilKit renders ink crisp at any zoom.
/// Paper sits underneath the ink and Claude's layer on top; both are resized to match the zoom.
/// Drawing coordinates are page coordinates (0..1000 x 0..1414) because contentSize = page size * zoomScale.
final class PageCanvasController: UIViewController, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    let paper = PaperView(frame: PageGeometry.rect)
    let claudeLayer = ClaudeLayerView(frame: PageGeometry.rect)
    let toolPicker = PKToolPicker()

    private(set) var page: Page?
    private var uploadTask: Task<Void, Never>?
    private var loading = false
    private var lastWidth: CGFloat = 0
    var onSyncState: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.93, alpha: 1)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = self
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.bouncesZoom = true
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Paper goes under PencilKit's own content view, Claude's layer above it.
        canvas.insertSubview(paper, at: 0)
        canvas.addSubview(claudeLayer)

        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = canvas.bounds.width
        guard width > 0, width != lastWidth else { return }
        // Fit the page to the width; allow zooming in 5x from there.
        let fit = width / PageGeometry.width
        let relative = lastWidth > 0 ? canvas.zoomScale / (lastWidth / PageGeometry.width) : 1
        lastWidth = width
        canvas.minimumZoomScale = fit
        canvas.maximumZoomScale = fit * 5
        canvas.zoomScale = fit * max(1, relative)
        layoutLayers(redraw: true)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        layoutLayers(redraw: false)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        layoutLayers(redraw: true)
    }

    /// Keep content size, paper and Claude's layer matched to the current zoom. While pinching we just
    /// stretch the old bitmaps; when the pinch ends we redraw them at the new resolution.
    private func layoutLayers(redraw: Bool) {
        let s = canvas.zoomScale
        let size = CGSize(width: PageGeometry.width * s, height: PageGeometry.height * s)
        canvas.contentSize = size
        // Center horizontally when zoomed out past the width (e.g. during a pinch bounce).
        let inset = max(0, (canvas.bounds.width - size.width) / 2)
        canvas.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 120, right: inset)
        for layer in [paper, claudeLayer] as [UIView] {
            layer.frame = CGRect(origin: .zero, size: size)
            if redraw { layer.setNeedsDisplay() }
        }
    }

    var pencilOnly: Bool {
        get { canvas.drawingPolicy == .pencilOnly }
        set { canvas.drawingPolicy = newValue ? .pencilOnly : .anyInput }
    }

    var showClaude: Bool {
        get { !claudeLayer.isHidden }
        set { claudeLayer.isHidden = !newValue }
    }

    /// Switch to another page. Saves the current one first.
    func show(_ page: Page) {
        if let old = self.page, old.id != page.id { flush() }
        let isNew = self.page?.id != page.id
        self.page = page
        paper.background = page.background
        claudeLayer.items = page.claudeLayer
        guard isNew else { return }
        paper.pdfPage = nil
        if let ref = page.pdf {
            let id = page.id
            Task {
                let pdfPage = await PDFCache.page(ref)
                if self.page?.id == id { self.paper.pdfPage = pdfPage }
            }
        }
        loading = true
        canvas.drawing = LocalDrawings.load(page.id) ?? PKDrawing()
        loading = false
        canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: 0), animated: false)
        if canvas.drawing.strokes.isEmpty {
            // Fresh install or new device: pull the backup from the server.
            let id = page.id
            Task {
                guard let data = try? await API.current?.drawing(pageId: id), let drawing = try? PKDrawing(data: data), self.page?.id == id else { return }
                self.loading = true
                self.canvas.drawing = drawing
                self.loading = false
                LocalDrawings.save(drawing, pageId: id)
            }
        }
    }

    func reloadClaudeLayer() {
        guard let id = page?.id else { return }
        Task {
            guard let items = try? await API.current?.claudeItems(pageId: id), self.page?.id == id else { return }
            self.page?.claudeLayer = items
            self.claudeLayer.items = items
        }
    }

    /// Used by the CI smoke test: a known stroke so we can check coordinates survive the round trip.
    func addTestStroke() {
        var points: [PKStrokePoint] = []
        for i in 0...48 {
            let a = Double(i) / 48 * 2 * .pi
            points.append(PKStrokePoint(location: CGPoint(x: 500 + 150 * cos(a), y: 700 + 150 * sin(a)), timeOffset: Double(i) * 0.01,
                                        size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .systemBlue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke])
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loading, let page else { return }
        LocalDrawings.save(canvasView.drawing, pageId: page.id)
        scheduleUpload(delay: 1.5)
    }

    /// Upload right away (used when leaving a page or the app going to background).
    func flush() {
        guard uploadTask != nil else { return }
        scheduleUpload(delay: 0)
    }

    private func scheduleUpload(delay: Double) {
        guard let page else { return }
        uploadTask?.cancel()
        let drawing = canvas.drawing
        let pdfPage = paper.pdfPage
        onSyncState?("unsynced")
        uploadTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let api = API.current else { return }
            onSyncState?("syncing")
            do {
                let png = PageSnapshot.png(drawing: drawing, background: page.background, pdf: pdfPage)
                let boxes = await PageSnapshot.recognizeText(drawing: drawing)
                try await api.uploadSnapshot(pageId: page.id, png: png, textBoxes: boxes)
                try await api.uploadDrawing(pageId: page.id, data: drawing.dataRepresentation())
                onSyncState?("synced")
            } catch {
                onSyncState?("offline")
            }
            if !Task.isCancelled { uploadTask = nil }
        }
    }
}

/// SwiftUI wrapper. The controller is owned by the editor so toolbar buttons can talk to it.
struct PageCanvas: UIViewControllerRepresentable {
    let controller: PageCanvasController

    func makeUIViewController(context: Context) -> PageCanvasController { controller }
    func updateUIViewController(_ vc: PageCanvasController, context: Context) {}
}
