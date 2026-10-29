import PencilKit
import SwiftUI
import UIKit

/// Where each page sits in the continuous scroll, in page units (one unit is one server coordinate).
enum NotebookLayout {
    static let gap: CGFloat = 28
    static let pitch = PageGeometry.height + gap

    static func offset(_ i: Int) -> CGFloat { CGFloat(i) * pitch }

    static func height(pages: Int) -> CGFloat { max(PageGeometry.height, CGFloat(pages) * pitch - gap) }

    /// The page under a y position; the gap after a page counts as that page.
    static func index(forY y: CGFloat, count: Int) -> Int {
        min(max(0, count - 1), max(0, Int(floor(y / pitch))))
    }

    /// The page a stroke belongs to: whichever page its middle is nearest, so ink in a gap is split down the middle.
    static func page(forStrokeAt y: CGFloat, count: Int) -> Int {
        index(forY: y + gap / 2, count: count)
    }

    /// The viewport's center determines the active page, so keep a search match at that center.
    static func centeredTop(for region: PageRegion, onPage index: Int, viewportHeight: CGFloat, insetTop: CGFloat) -> CGFloat {
        let center = min(PageGeometry.height - 1, max(0, CGFloat(region.y + region.h / 2)))
        return offset(index) + center - viewportHeight / 2 + insetTop
    }

    /// A selection belongs to the page where the drag began. Clip at its edges, including page gaps.
    static func region(from start: CGPoint, to end: CGPoint, count: Int) -> (Int, PageRegion)? {
        guard count > 0, PageGeometry.rect.contains(CGPoint(x: start.x, y: start.y.truncatingRemainder(dividingBy: pitch))), start.y >= 0 else { return nil }
        let index = Int(floor(start.y / pitch))
        guard index < count else { return nil }
        let page = CGRect(x: 0, y: offset(index), width: PageGeometry.width, height: PageGeometry.height)
        let drag = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let clipped = drag.intersection(page)
        guard !clipped.isNull, clipped.width >= 15, clipped.height >= 15 else { return nil }
        return (index, PageRegion(x: Double(clipped.minX), y: Double(clipped.minY - page.minY),
                                  w: Double(clipped.width), h: Double(clipped.height)))
    }
}

/// Lets only its controls take touches; PencilKit still receives ink and scroll gestures elsewhere.
final class ControlOverlay: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        for child in subviews.reversed() {
            let target = child.hitTest(convert(point, to: child), with: event)
            if let target { return target }
        }
        return nil
    }

    func refreshAccessibilityElements() {
        isAccessibilityElement = false
        accessibilityElements = isHidden ? [] : subviews.filter {
            $0.isAccessibilityElement && !$0.isHidden && $0.alpha > 0.01 && $0.frame.intersects(bounds)
        }
    }
}

final class RegionSelectionView: UIView {
    var onFinish: ((CGPoint, CGPoint) -> Void)?
    var onAccessibleSelect: (() -> Void)?
    private var start: CGPoint?
    private var end: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        accessibilityLabel = "Drag to select a question for Claude"
        accessibilityIdentifier = "doubt.selection"
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Double tap to mark the visible part of the current page"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityActivate() -> Bool {
        guard let onAccessibleSelect else { return false }
        onAccessibleSelect()
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        start = point; end = point; setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        end = touches.first?.location(in: self); setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let start, let end = touches.first?.location(in: self) else { return }
        self.start = nil; self.end = nil; setNeedsDisplay()
        onFinish?(start, end)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        start = nil; end = nil; setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let start, let end, let ctx = UIGraphicsGetCurrentContext() else { return }
        let selected = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
        ctx.setFillColor(UIColor(hex: "#D97757").withAlphaComponent(0.12).cgColor)
        ctx.fill(selected)
        ctx.setStrokeColor(UIColor(hex: "#D97757").cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [7, 5])
        ctx.stroke(selected)
    }
}

/// The whole notebook as one vertical scroll, like GoodNotes or Notes.
///
/// One PKCanvasView spans every page and is itself the zooming scroll view, so PencilKit keeps ink crisp
/// at any zoom. Its drawing coordinates are notebook coordinates: page i occupies y = offset(i) ..< offset(i) + 1414.
/// Each page's ink is stored separately in that page's own coordinates (what the server and Claude use),
/// and split back out of the canvas after every edit. Paper sits under the ink and Claude's layer over it,
/// as tiled views that exist only for pages near the screen.
final class NotebookCanvasController: UIViewController, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    let toolPicker = PKToolPicker()
    private let paperContainer = UIView()
    private let claudeContainer = UIView()
    private let hintOverlay = ControlOverlay()
    private var hintButtons: [String: UIButton] = [:]
    private var selectionOverlay: RegionSelectionView?
    private let footer = UILabel()

    private(set) var notebookId: String?
    private(set) var pages: [Page] = []
    private(set) var currentIndex = 0
    /// Ink per page id, in page coordinates.
    private var drawings: [String: PKDrawing] = [:]
    private var fingerprints: [String: Int] = [:]
    private var onScreen: [String: (paper: PaperView, claude: ClaudeLayerView)] = [:]
    private var commitTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var viewTask: Task<Void, Never>?
    private var loading = false
    private var lastWidth: CGFloat = 0
    private var pendingScroll: CGFloat?
    private var pendingRegion: (pageIndex: Int, region: PageRegion)?
    private var pullArmed = false
    private(set) var dark = false
    private(set) var invertPDFs = true

    var onSyncState: ((String) -> Void)?
    var onPageChange: ((Int) -> Void)?
    var onPullToAdd: (() -> Void)?
    var onDoubtRegion: ((String, PageRegion) -> Void)?
    var onHintError: ((String) -> Void)?
    var onSelectionError: (() -> Void)?

    private static let footerInset: CGFloat = 140
    private static let pullDistance: CGFloat = 70

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#151A1D") : UIColor(hex: "#EDE8DF") }

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = self
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.alwaysBounceVertical = true
        canvas.bouncesZoom = true
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Paper and Claude's tiled ink live in notebook coordinates and never take touches.
        for container in [paperContainer, claudeContainer] {
            container.backgroundColor = .clear
            container.isUserInteractionEnabled = false
        }
        canvas.insertSubview(paperContainer, at: 0)
        canvas.addSubview(claudeContainer)

        // PencilKit owns its accessibility tree. Keep real hint controls beside the canvas so both
        // VoiceOver and touch can reach them, converting their positions into viewport coordinates.
        hintOverlay.translatesAutoresizingMaskIntoConstraints = false
        hintOverlay.backgroundColor = .clear
        hintOverlay.clipsToBounds = true
        view.addSubview(hintOverlay)
        NSLayoutConstraint.activate([
            hintOverlay.topAnchor.constraint(equalTo: canvas.topAnchor),
            hintOverlay.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            hintOverlay.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            hintOverlay.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])

        footer.text = "Pull up to add a page"
        footer.font = .preferredFont(forTextStyle: .footnote)
        footer.textColor = .secondaryLabel
        footer.textAlignment = .center
        canvas.addSubview(footer)

        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHintButtons()
        let width = canvas.bounds.width
        guard width > 0, width != lastWidth else { return }
        // Fit the page to the width; allow zooming in 5x from there. Keep the same spot on screen on rotation.
        let fit = width / PageGeometry.width
        let top = lastWidth > 0 ? topY : nil
        let relative = lastWidth > 0 ? canvas.zoomScale / (lastWidth / PageGeometry.width) : 1
        lastWidth = width
        canvas.minimumZoomScale = fit
        canvas.maximumZoomScale = fit * 5
        canvas.zoomScale = fit * max(1, relative)
        layoutContent()
        if let top { scroll(toY: top, animated: false) }
        applyPendingScroll()
    }

    // MARK: Layout

    /// The notebook y (page units) at the top of the screen.
    private var topY: CGFloat { (canvas.contentOffset.y + canvas.adjustedContentInset.top) / canvas.zoomScale }

    private func layoutContent() {
        let s = canvas.zoomScale
        let size = CGSize(width: PageGeometry.width * s, height: NotebookLayout.height(pages: pages.count) * s)
        canvas.contentSize = size
        // Center horizontally when zoomed out past the width (e.g. during a pinch bounce).
        let side = max(0, (canvas.bounds.width - size.width) / 2)
        canvas.contentInset = UIEdgeInsets(top: 16, left: side, bottom: Self.footerInset, right: side)
        paperContainer.frame = CGRect(origin: .zero, size: size)
        claudeContainer.frame = CGRect(origin: .zero, size: size)
        footer.frame = CGRect(x: 0, y: size.height + 36, width: size.width, height: 24)
        updateVisiblePages()
    }

    /// Only pages on or next to the screen get paper and Claude views; the rest are released.
    private func updateVisiblePages() {
        guard !pages.isEmpty, canvas.zoomScale > 0 else { return }
        let s = canvas.zoomScale
        let top = canvas.contentOffset.y / s, bottom = (canvas.contentOffset.y + canvas.bounds.height) / s
        let first = max(0, NotebookLayout.index(forY: top, count: pages.count) - 1)
        let last = min(pages.count - 1, NotebookLayout.index(forY: bottom, count: pages.count) + 1)
        var keep = Set<String>()
        for i in first...last {
            let page = pages[i]
            keep.insert(page.id)
            let views = onScreen[page.id] ?? makeViews(for: page)
            for v in [views.paper, views.claude] as [UIView] {
                v.bounds = PageGeometry.rect
                v.transform = CGAffineTransform(scaleX: s, y: s)
                v.center = CGPoint(x: PageGeometry.width / 2 * s, y: (NotebookLayout.offset(i) + PageGeometry.height / 2) * s)
            }
        }
        for (id, views) in onScreen where !keep.contains(id) {
            views.paper.removeFromSuperview()
            views.claude.removeFromSuperview()
            onScreen[id] = nil
        }
        updateHintButtons()
    }

    private func makeViews(for page: Page) -> (paper: PaperView, claude: ClaudeLayerView) {
        let paper = PaperView(frame: PageGeometry.rect)
        paper.style = style(for: page)
        let claude = ClaudeLayerView(frame: PageGeometry.rect)
        claude.update(items: page.claudeLayer, dark: page.usesDarkInkPalette(appDark: dark), doubts: page.doubts ?? [])
        paperContainer.addSubview(paper)
        claudeContainer.addSubview(claude)
        let views = (paper: paper, claude: claude)
        onScreen[page.id] = views
        if let ref = page.pdf, PDFCache.cached(ref) == nil {
            let id = page.id
            Task {
                guard let pdf = await PDFCache.page(ref), let v = self.onScreen[id] else { return }
                var style = v.paper.style
                style.pdf = pdf
                v.paper.style = style
            }
        }
        return views
    }

    private func style(for page: Page) -> PaperStyle {
        PaperStyle(background: page.background, paper: page.paper, pdf: page.pdf.flatMap { PDFCache.cached($0) }, dark: dark, invertPDF: invertPDFs)
    }

    private func clampedOffsetY(_ y: CGFloat) -> CGFloat {
        let inset = canvas.adjustedContentInset
        let maxY = max(-inset.top, canvas.contentSize.height + inset.bottom - canvas.bounds.height)
        return min(max(y, -inset.top), maxY)
    }

    /// Scroll so notebook y (page units) is at the top of the screen.
    func scroll(toY y: CGFloat, animated: Bool) {
        pendingRegion = nil
        guard lastWidth > 0, !pages.isEmpty else { pendingScroll = y; return }
        let offset = clampedOffsetY(y * canvas.zoomScale - canvas.adjustedContentInset.top)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: offset), animated: animated)
        updateVisiblePages()
        updateCurrentPage()
    }

    func scrollTo(page i: Int, animated: Bool) {
        scroll(toY: NotebookLayout.offset(i), animated: animated)
    }

    func scrollToRegion(pageIndex: Int, region: PageRegion) {
        guard pages.indices.contains(pageIndex) else { return }
        guard lastWidth > 0, canvas.zoomScale > 0 else {
            pendingRegion = (pageIndex, region)
            pendingScroll = nil
            return
        }
        let scale = canvas.zoomScale
        let top = NotebookLayout.centeredTop(for: region, onPage: pageIndex,
                                             viewportHeight: canvas.bounds.height / scale,
                                             insetTop: canvas.adjustedContentInset.top / scale)
        scroll(toY: top, animated: false)
    }

    private func applyPendingScroll() {
        if let pendingRegion, lastWidth > 0, !pages.isEmpty {
            self.pendingRegion = nil
            scrollToRegion(pageIndex: pendingRegion.pageIndex, region: pendingRegion.region)
            updateCurrentPage(force: true)
            return
        }
        guard let y = pendingScroll, lastWidth > 0, !pages.isEmpty else { return }
        pendingScroll = nil
        scroll(toY: y, animated: false)
        updateCurrentPage(force: true)
    }

    // MARK: Scrolling and zooming

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisiblePages()
        updateCurrentPage()
        if scrollView.isDragging {
            pullArmed = bottomOverscroll > Self.pullDistance
            footer.text = pullArmed ? "Release to add a page" : "Pull up to add a page"
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        layoutContent()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard pullArmed else { return }
        pullArmed = false
        footer.text = "Adding a page…"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onPullToAdd?()
    }

    /// Called once the page that a pull asked for is in (or failed to arrive).
    func endPullToAdd() {
        footer.text = "Pull up to add a page"
    }

    /// How far the user has dragged past the end of the last page's footer.
    private var bottomOverscroll: CGFloat {
        let inset = canvas.adjustedContentInset
        let maxY = max(-inset.top, canvas.contentSize.height + inset.bottom - canvas.bounds.height)
        return canvas.contentOffset.y - maxY
    }

    /// The page in the middle of the screen is "the page", for the title and for Claude.
    private func updateCurrentPage(force: Bool = false) {
        guard !pages.isEmpty, canvas.zoomScale > 0 else { return }
        let mid = (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale
        let i = NotebookLayout.index(forY: mid, count: pages.count)
        guard i != currentIndex || force else { return }
        currentIndex = i
        // Async: this can run inside a layout pass that SwiftUI started, where changing its state is not allowed.
        DispatchQueue.main.async { self.onPageChange?(i) }
        reportView()
    }

    /// Tell the server which page is on screen, so "look at my page" just works in Claude.
    private func reportView() {
        guard let nb = notebookId, pages.indices.contains(currentIndex) else { return }
        let pageId = pages[currentIndex].id
        UserDefaults.standard.set(currentIndex, forKey: "lastPage.\(nb)")
        viewTask?.cancel()
        viewTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await API.current?.setView(notebookId: nb, pageId: pageId)
        }
    }

    // MARK: Settings from the editor

    var pencilOnly: Bool {
        get { canvas.drawingPolicy == .pencilOnly }
        set { canvas.drawingPolicy = newValue ? .pencilOnly : .anyInput }
    }

    var showClaude: Bool {
        get { !claudeContainer.isHidden }
        set {
            claudeContainer.isHidden = !newValue
            hintOverlay.isHidden = !newValue
            hintOverlay.refreshAccessibilityElements()
        }
    }

    func setAppearance(dark: Bool, invertPDFs: Bool) {
        guard dark != self.dark || invertPDFs != self.invertPDFs else { return }
        self.dark = dark
        self.invertPDFs = invertPDFs
        toolPicker.overrideUserInterfaceStyle = dark ? .dark : .light
        for (id, views) in onScreen {
            guard let page = pages.first(where: { $0.id == id }) else { continue }
            var style = views.paper.style
            style.dark = dark
            style.invertPDF = invertPDFs
            views.paper.style = style
            views.claude.update(items: page.claudeLayer, dark: page.usesDarkInkPalette(appDark: dark), doubts: page.doubts ?? [])
        }
        updateHintButtons()
    }

    // MARK: Notebook content

    /// Show a notebook, or refresh the one on screen. If only Claude's layers changed, the ink is left alone.
    func setNotebook(_ notebook: Notebook) {
        let first = notebookId != notebook.id
        if !first && notebook.pages.map(\.id) == pages.map(\.id) {
            let changedPaper = notebook.pages.filter { next in pages.contains { $0.id == next.id && ($0.background != next.background || $0.paper != next.paper) } }.map(\.id)
            pages = notebook.pages
            PendingUploads.all.formUnion(changedPaper.filter { LocalDrawings.exists($0) })
            if !changedPaper.isEmpty { scheduleUpload(delay: 0.2) }
            for (id, views) in onScreen {
                if let page = pages.first(where: { $0.id == id }) { views.paper.style = style(for: page); views.claude.update(items: page.claudeLayer, dark: page.usesDarkInkPalette(appDark: dark), doubts: page.doubts ?? []) }
            }
            updateHintButtons()
            return
        }

        // Pages were added (or this is the first load). Capture ink under the old layout, then re-lay it out.
        commitNow()
        let anchor = pages.indices.contains(currentIndex) ? pages[NotebookLayout.index(forY: topY, count: pages.count)].id : nil
        let anchorDelta = anchor.flatMap { id in pages.firstIndex { $0.id == id } }.map { topY - NotebookLayout.offset($0) }
        notebookId = notebook.id
        pages = notebook.pages
        let retained = Set(pages.map(\.id))
        drawings = drawings.filter { retained.contains($0.key) }
        fingerprints = fingerprints.filter { retained.contains($0.key) }
        for page in pages where drawings[page.id] == nil {
            let drawing = LocalDrawings.load(page.id) ?? PKDrawing()
            drawings[page.id] = drawing
            fingerprints[page.id] = Self.fingerprint(drawing.strokes, dy: 0)
        }
        rebuildCanvasDrawing()
        for views in onScreen.values {
            views.paper.removeFromSuperview()
            views.claude.removeFromSuperview()
        }
        onScreen = [:]
        for button in hintButtons.values { button.removeFromSuperview() }
        hintButtons = [:]
        layoutContent()

        if first {
            let saved = UserDefaults.standard.integer(forKey: "lastPage.\(notebook.id)")
            currentIndex = max(0, min(saved, pages.count - 1))
            pendingScroll = NotebookLayout.offset(currentIndex)
            applyPendingScroll()
            if !pendingIds.isEmpty { scheduleUpload(delay: 1) }
        } else if let anchor, let anchorDelta, let i = pages.firstIndex(where: { $0.id == anchor }) {
            // Keep whatever was on screen in place, even if pages were inserted above it.
            scroll(toY: NotebookLayout.offset(i) + anchorDelta, animated: false)
            updateCurrentPage(force: true)
        } else {
            currentIndex = min(currentIndex, max(0, pages.count - 1))
            if !pages.isEmpty { scrollTo(page: currentIndex, animated: false); updateCurrentPage(force: true) }
        }
        // Newly duplicated/moved pages can have a server backup too.
        restoreBackups()
        footer.text = "Pull up to add a page"
    }

    /// Claude drew on a page: refresh just that page's layer.
    func reloadClaudeLayer(pageId: String) {
        guard pages.contains(where: { $0.id == pageId }) else { return }
        Task {
            guard let items = try? await API.current?.claudeItems(pageId: pageId),
                  let i = self.pages.firstIndex(where: { $0.id == pageId }) else { return }
            self.pages[i].claudeLayer = items
            self.onScreen[pageId]?.claude.update(items: items, dark: self.pages[i].usesDarkInkPalette(appDark: self.dark), doubts: self.pages[i].doubts ?? [])
            self.updateHintButtons()
        }
    }

    func reloadDoubts(pageId: String) {
        guard pages.contains(where: { $0.id == pageId }) else { return }
        Task {
            guard let doubts = try? await API.current?.doubts(pageId: pageId),
                  let i = self.pages.firstIndex(where: { $0.id == pageId }) else { return }
            self.pages[i].doubts = doubts
            self.onScreen[pageId]?.claude.update(items: self.pages[i].claudeLayer, dark: self.pages[i].usesDarkInkPalette(appDark: self.dark), doubts: doubts)
        }
    }

    func addDoubt(_ doubt: Doubt) {
        guard let index = pages.firstIndex(where: { $0.id == doubt.pageId }) else { return }
        var doubts = pages[index].doubts ?? []
        doubts.removeAll { $0.id == doubt.id }
        doubts.append(doubt)
        pages[index].doubts = doubts
        onScreen[doubt.pageId]?.claude.update(items: pages[index].claudeLayer, dark: pages[index].usesDarkInkPalette(appDark: dark), doubts: doubts)
    }

    /// Selection points live in screen coordinates. Convert through the scroll view so zoom and offsets
    /// produce the same 1000 x 1414 page region that Claude sees.
    func beginDoubtSelection() {
        guard selectionOverlay == nil, !pages.isEmpty else { return }
        flush()
        canvas.setContentOffset(canvas.contentOffset, animated: false)
        toolPicker.setVisible(false, forFirstResponder: canvas)
        let overlay = RegionSelectionView(frame: canvas.frame)
        overlay.onAccessibleSelect = { [weak self] in
            guard let self, let page = self.currentPage else { return }
            let s = self.canvas.zoomScale
            guard s > 0 else { return }
            let visible = CGRect(x: self.canvas.contentOffset.x / s, y: self.canvas.contentOffset.y / s,
                                 width: self.canvas.bounds.width / s, height: self.canvas.bounds.height / s)
            let pageRect = CGRect(x: 0, y: NotebookLayout.offset(self.currentIndex), width: PageGeometry.width, height: PageGeometry.height)
            let selected = visible.intersection(pageRect)
            guard !selected.isNull, selected.width >= 15, selected.height >= 15 else { return }
            self.cancelDoubtSelection()
            self.onDoubtRegion?(page.id, PageRegion(x: Double(selected.minX), y: Double(selected.minY - pageRect.minY),
                                                  w: Double(selected.width), h: Double(selected.height)))
        }
        overlay.onFinish = { [weak self, weak overlay] start, end in
            guard let self, let overlay else { return }
            let a = self.paperContainer.convert(start, from: overlay)
            let b = self.paperContainer.convert(end, from: overlay)
            let scale = self.canvas.zoomScale
            guard scale > 0 else { return }
            let first = CGPoint(x: a.x / scale, y: a.y / scale)
            let last = CGPoint(x: b.x / scale, y: b.y / scale)
            guard let (pageIndex, region) = NotebookLayout.region(from: first, to: last, count: self.pages.count) else {
                self.onSelectionError?()
                return
            }
            self.cancelDoubtSelection()
            self.onDoubtRegion?(self.pages[pageIndex].id, region)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: canvas.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])
        selectionOverlay = overlay
    }

    func cancelDoubtSelection() {
        guard selectionOverlay != nil else { return }
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
        toolPicker.setVisible(true, forFirstResponder: canvas)
    }

    private func updateHintButtons() {
        guard canvas.zoomScale > 0 else { return }
        let visible = pages.enumerated().filter { onScreen[$0.element.id] != nil }
        var wanted = Set<String>()
        for (index, page) in visible {
            for item in page.claudeLayer where item.type == "hint" && item.revealed != true {
                guard let x = item.x, let y = item.y else { continue }
                let key = "\(page.id):\(item.id)"
                wanted.insert(key)
                let button: UIButton
                if let existing = hintButtons[key] { button = existing } else {
                    button = UIButton(type: .system)
                    button.isAccessibilityElement = true
                    button.accessibilityTraits = .button
                    button.accessibilityIdentifier = "hint.\(item.id)"
                    button.accessibilityHint = "Reveal Claude's hidden hint"
                    button.addAction(UIAction { [weak self, weak button] _ in
                        guard let api = API.current else { return }
                        button?.isEnabled = false
                        Task {
                            defer { button?.isEnabled = true }
                            do {
                                let revealed = try await api.revealHint(pageId: page.id, itemId: item.id)
                                self?.applyHint(revealed, pageId: page.id)
                            } catch { self?.onHintError?(error.localizedDescription) }
                        }
                    }, for: .touchUpInside)
                    hintOverlay.addSubview(button)
                    hintButtons[key] = button
                }
                button.accessibilityLabel = item.label ?? "Hint"
                let s = canvas.zoomScale
                // The tiled layer draws the chip in page units. Its transparent target grows to 44pt.
                let pageChip = CGRect(x: CGFloat(x) * s, y: (NotebookLayout.offset(index) + CGFloat(y)) * s,
                                      width: CGFloat(item.w ?? 100) * s, height: CGFloat(item.h ?? 34) * s)
                let chip = claudeContainer.convert(pageChip, to: hintOverlay)
                button.frame = chip.insetBy(dx: -max(0, (44 - chip.width) / 2), dy: -max(0, (44 - chip.height) / 2))
                button.isHidden = !button.frame.intersects(hintOverlay.bounds)
            }
        }
        for key in hintButtons.keys.filter({ !wanted.contains($0) }) {
            hintButtons[key]?.removeFromSuperview()
            hintButtons[key] = nil
        }
        hintOverlay.refreshAccessibilityElements()
    }

    private func applyHint(_ item: ClaudeItem, pageId: String) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageId }),
              let itemIndex = pages[pageIndex].claudeLayer.firstIndex(where: { $0.id == item.id }) else { return }
        pages[pageIndex].claudeLayer[itemIndex] = item
        onScreen[pageId]?.claude.update(items: pages[pageIndex].claudeLayer, dark: pages[pageIndex].usesDarkInkPalette(appDark: dark), doubts: pages[pageIndex].doubts ?? [])
        updateHintButtons()
        UIAccessibility.post(notification: .announcement, argument: item.text ?? "Hint revealed")
    }

    var currentPage: Page? { pages.indices.contains(currentIndex) ? pages[currentIndex] : nil }

    private func rebuildCanvasDrawing() {
        var combined = PKDrawing()
        for (i, page) in pages.enumerated() {
            guard let drawing = drawings[page.id], !drawing.strokes.isEmpty else { continue }
            combined.append(drawing.transformed(using: CGAffineTransform(translationX: 0, y: NotebookLayout.offset(i))))
        }
        loading = true
        canvas.drawing = combined
        loading = false
    }

    /// Fresh install or new device: pull each page's ink backup from the server.
    /// Rebuild paper-baked snapshots only after the local ink is known, including after an offline change.
    private func refreshPaperSnapshots() {
        let stale = pages.filter { $0.paperSnapshotStale == true && LocalDrawings.exists($0.id) }.map(\.id)
        if !stale.isEmpty { PendingUploads.all.formUnion(stale); scheduleUpload(delay: 0.5) }
    }

    private func restoreBackups() {
        refreshPaperSnapshots()
        let missing = pages.map(\.id).filter { !LocalDrawings.exists($0) }
        guard !missing.isEmpty, let api = API.current else { return }
        Task {
            let results = await withTaskGroup(of: (String, Data?, Bool).self) { group -> [(String, Data?, Bool)] in
                for id in missing {
                    group.addTask {
                        do {
                            return (id, try await api.drawing(pageId: id), true)
                        } catch {
                            return (id, nil, false)
                        }
                    }
                }
                var out: [(String, Data?, Bool)] = []
                for await result in group { out.append(result) }
                return out
            }
            var restored: [String: PKDrawing] = [:]
            for (id, data, reached) in results {
                guard self.pages.contains(where: { $0.id == id }), !LocalDrawings.isDeleted(id) else { continue }
                if let data, let drawing = try? PKDrawing(data: data) { restored[id] = drawing }
                // The server has no ink for this page either: remember that so we don't ask again,
                // unless the user has drawn on it in the meantime (that already saved a file).
                else if reached && data == nil && !LocalDrawings.exists(id) && (drawings[id]?.strokes.isEmpty ?? true) {
                    LocalDrawings.save(PKDrawing(), pageId: id)
                }
            }
            guard !restored.isEmpty else { refreshPaperSnapshots(); return }
            commitNow()
            for (id, drawing) in restored where pages.contains(where: { $0.id == id }) && !LocalDrawings.isDeleted(id) && (drawings[id]?.strokes.isEmpty ?? true) {
                drawings[id] = drawing
                fingerprints[id] = Self.fingerprint(drawing.strokes, dy: 0)
                LocalDrawings.save(drawing, pageId: id)
            }
            rebuildCanvasDrawing()
            refreshPaperSnapshots()
        }
    }

    /// Used by the CI smoke test: known strokes so we can check coordinates survive the round trip. A circle
    /// and a line on page 1, and a zigzag near the top of page 2 to check ink is split between pages.
    func addTestStroke() {
        func stroke(_ pts: [CGPoint]) -> PKStroke {
            let points = pts.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 5, height: 5),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .systemBlue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        var strokes = [
            stroke((0...48).map { i in
                let a = Double(i) / 48 * 2 * .pi
                return CGPoint(x: 500 + 150 * cos(a), y: 700 + 150 * sin(a))
            }),
            stroke((0...20).map { CGPoint(x: 100 + Double($0) * 40, y: 1300) }),
        ]
        if pages.count > 1 {
            let top = NotebookLayout.offset(1)
            strokes.append(stroke((0...8).map { CGPoint(x: 150 + CGFloat($0) * 90, y: top + ($0 % 2 == 0 ? 160 : 260)) }))
        }
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + strokes)
    }

    // MARK: Saving and syncing

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loading, !pages.isEmpty else { return }
        onSyncState?("unsynced")
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.commitNow()
        }
    }

    /// Split the canvas back into pages; save and queue an upload for each page whose ink changed.
    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        guard !pages.isEmpty else { return }
        var buckets = Array(repeating: [PKStroke](), count: pages.count)
        for stroke in canvas.drawing.strokes {
            buckets[NotebookLayout.page(forStrokeAt: stroke.renderBounds.midY, count: pages.count)].append(stroke)
        }
        var changed = false
        for (i, page) in pages.enumerated() {
            let dy = NotebookLayout.offset(i)
            let fp = Self.fingerprint(buckets[i], dy: dy)
            guard fp != fingerprints[page.id] else { continue }
            let drawing = PKDrawing(strokes: buckets[i]).transformed(using: CGAffineTransform(translationX: 0, y: -dy))
            drawings[page.id] = drawing
            fingerprints[page.id] = fp
            LocalDrawings.save(drawing, pageId: page.id)
            PendingUploads.all.insert(page.id)
            changed = true
        }
        if changed { scheduleUpload(delay: 1.5) } else if pendingIds.isEmpty { onSyncState?("synced") }
    }

    /// Cheap change detector for a page's strokes. Positions are rounded so moving ink between notebook and
    /// page coordinates doesn't register as an edit.
    private static func fingerprint(_ strokes: [PKStroke], dy: CGFloat) -> Int {
        var h = Hasher()
        func q(_ v: CGFloat) -> Int { Int((v * 64).rounded()) }
        h.combine(strokes.count)
        for s in strokes {
            let b = s.renderBounds
            h.combine(q(b.minX)); h.combine(q(b.minY - dy)); h.combine(q(b.width)); h.combine(q(b.height))
            h.combine(s.path.count)
            h.combine(s.path.creationDate)
            h.combine(s.ink.inkType.rawValue)
            h.combine(s.ink.color)
            if let mask = s.mask {
                var elements = 0
                mask.cgPath.applyWithBlock { _ in elements += 1 }
                h.combine(elements)
                h.combine(q(mask.bounds.width)); h.combine(q(mask.bounds.height))
            }
        }
        return h.finalize()
    }

    /// Queued page uploads that belong to this notebook.
    private var pendingIds: Set<String> {
        let ids = Set(pages.map(\.id))
        return PendingUploads.all.filter { ids.contains($0) }
    }

    /// Capture current ink, cancel queued work and wait out any request already in
    /// flight. Explicit deletion may discard unsynced ink, so it does not upload.
    func pauseUploads() async {
        let previous = uploadTask
        previous?.cancel()
        commitNow()
        let queued = uploadTask
        queued?.cancel()
        await previous?.value
        await queued?.value
        uploadTask = nil
    }

    /// Duplicating a page must use its latest saved handwriting, not an older backup.
    func flushAndWait() async throws {
        await pauseUploads()
        await uploadPending()
        if !pendingIds.isEmpty {
            throw NSError(domain: "ClaudeBook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't save the latest handwriting. Check your connection and try again."])
        }
    }

    /// Called after confirmed deletion, before the editor's final disappearance flush.
    func discardPages(_ ids: [String]) {
        let removed = Set(ids)
        guard pages.contains(where: { removed.contains($0.id) }) else { return }
        commitTask?.cancel(); uploadTask?.cancel(); viewTask?.cancel()
        pages.removeAll { removed.contains($0.id) }
        for id in ids {
            drawings.removeValue(forKey: id); fingerprints.removeValue(forKey: id)
            if let views = onScreen.removeValue(forKey: id) {
                views.paper.removeFromSuperview(); views.claude.removeFromSuperview()
            }
        }
        currentIndex = min(currentIndex, max(0, pages.count - 1))
        rebuildCanvasDrawing()
        layoutContent()
        updateHintButtons()
    }

    /// Upload right away (used when leaving the notebook or the app going to background).
    func flush() {
        commitNow()
        if !pendingIds.isEmpty { scheduleUpload(delay: 0) }
    }

    private func scheduleUpload(delay: Double) {
        uploadTask?.cancel()
        onSyncState?("unsynced")
        uploadTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self.uploadPending()
        }
    }

    private func uploadPending() async {
        guard let api = API.current else { return }
        onSyncState?("syncing")
        var failed = false
        for id in pendingIds {
            guard !Task.isCancelled else { return }
            guard !LocalDrawings.isDeleted(id), let page = pages.first(where: { $0.id == id }) else { continue }
            let drawing = drawings[id] ?? PKDrawing()
            PendingUploads.all.remove(id)
            do {
                // Resolve the PDF here, not earlier: it may still have been downloading then.
                var pdf: CGPDFPage?
                if let ref = page.pdf { pdf = await PDFCache.page(ref) }
                let boxes = await PageSnapshot.recognizeText(drawing: drawing)
                // Without the PDF the snapshot would hide it from Claude, so let the server's own render stand.
                if page.pdf == nil || pdf != nil {
                    let png = PageSnapshot.png(drawing: drawing, background: page.background, paper: page.paper, pdf: pdf)
                    try await api.uploadSnapshot(pageId: id, png: png, textBoxes: boxes, strokeCount: drawing.strokes.count)
                }
                try await api.uploadDrawing(pageId: id, data: drawing.dataRepresentation(), strokeCount: drawing.strokes.count)
            } catch {
                if let apiError = error as? APIError, apiError.status == 404 {
                    LocalDrawings.remove([id])
                    continue
                }
                PendingUploads.all.insert(id)
                if Task.isCancelled { return }
                failed = true
            }
        }
        guard !Task.isCancelled else { return }
        if failed {
            onSyncState?("offline")
            // Try again in a bit; edits in the meantime reschedule sooner.
            uploadTask = Task {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await self.uploadPending()
            }
        } else {
            onSyncState?(pendingIds.isEmpty ? "synced" : "unsynced")
            uploadTask = nil
        }
    }
}

/// SwiftUI wrapper. The controller is owned by the editor so toolbar buttons can talk to it.
struct NotebookCanvas: UIViewControllerRepresentable {
    let controller: NotebookCanvasController
    var dark: Bool
    var invertPDFs: Bool

    func makeUIViewController(context: Context) -> NotebookCanvasController { controller }

    func updateUIViewController(_ vc: NotebookCanvasController, context: Context) {
        vc.setAppearance(dark: dark, invertPDFs: invertPDFs)
    }
}
