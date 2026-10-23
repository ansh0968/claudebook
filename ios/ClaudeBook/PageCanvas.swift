import PencilKit
import SwiftUI
import UIKit

/// One page: paper, the user's PencilKit ink, and Claude's layer on top, all in a zoomable 1000x1414 space.
final class PageCanvasController: UIViewController, PKCanvasViewDelegate, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let pageView = UIView(frame: PageGeometry.rect)
    let paper = PaperView(frame: PageGeometry.rect)
    let canvas = PKCanvasView(frame: PageGeometry.rect)
    let claudeLayer = ClaudeLayerView(frame: PageGeometry.rect)
    let toolPicker = PKToolPicker()

    private(set) var page: Page?
    private var uploadTask: Task<Void, Never>?
    private var loading = false
    var onSyncState: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.93, alpha: 1)

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        pageView.layer.shadowColor = UIColor.black.cgColor
        pageView.layer.shadowOpacity = 0.12
        pageView.layer.shadowRadius = 10
        scrollView.addSubview(pageView)
        pageView.addSubview(paper)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = self
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        pageView.addSubview(canvas)
        pageView.addSubview(claudeLayer)

        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fit = max(0.1, (scrollView.bounds.width - 32) / PageGeometry.width)
        let wasAtMin = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001
        scrollView.minimumZoomScale = fit
        if wasAtMin || scrollView.zoomScale < fit { scrollView.zoomScale = fit }
        centerPage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPage() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Re-rasterize at the new zoom so ink and Claude's layer stay sharp instead of a blurry bitmap.
        let s = scale * (self.view.window?.screen.scale ?? 2)
        for v in [paper, canvas, claudeLayer] as [UIView] {
            v.contentScaleFactor = s
            v.setNeedsDisplay()
        }
    }

    private func centerPage() {
        let size = scrollView.bounds.size, content = pageView.frame.size
        scrollView.contentInset = UIEdgeInsets(
            top: max(16, (size.height - content.height) / 2),
            left: max(16, (size.width - content.width) / 2),
            bottom: 16,
            right: max(16, (size.width - content.width) / 2)
        )
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
        loading = true
        canvas.drawing = LocalDrawings.load(page.id) ?? PKDrawing()
        loading = false
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
        onSyncState?("unsynced")
        uploadTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let api = API.current else { return }
            onSyncState?("syncing")
            do {
                let png = PageSnapshot.png(drawing: drawing, background: page.background)
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
