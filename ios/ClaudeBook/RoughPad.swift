import PencilKit
import SwiftUI
import UIKit

/// Rough work: quick scribble sheets that belong to one page and slide in from the right edge.
/// They live on this iPad only (Application Support/rough/<pageId>.json), never in the notebook
/// itself, so the page stays clean and Claude's snapshots are unchanged.
struct RoughSheet: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var ink = Data()
    var strokes = 0

    var isEmpty: Bool { strokes == 0 }
}

enum RoughStore {
    private static let dir: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "rough", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func url(_ pageId: String) -> URL { dir.appending(path: "\(pageId).json") }

    static func load(_ pageId: String) -> [RoughSheet] {
        guard let data = try? Data(contentsOf: url(pageId)) else { return [] }
        return (try? JSONDecoder().decode([RoughSheet].self, from: data)) ?? []
    }

    /// Empty sheets are dropped; a page with no ink left loses its file.
    static func save(_ sheets: [RoughSheet], pageId: String) {
        let kept = sheets.filter { !$0.isEmpty }
        if kept.isEmpty {
            try? FileManager.default.removeItem(at: url(pageId))
        } else if let data = try? JSONEncoder().encode(kept) {
            try? data.write(to: url(pageId), options: .atomic)
        }
    }

    static func remove(_ pageIds: [String]) {
        for id in pageIds { try? FileManager.default.removeItem(at: url(id)) }
    }
}

/// The drawer's state for whichever page is in the middle of the screen.
@MainActor
final class RoughModel: ObservableObject {
    @Published private(set) var pageId: String?
    @Published private(set) var sheets = [RoughSheet()]
    @Published var selected = 0
    @Published var isOpen = false {
        didSet { if !isOpen { flush() } }
    }
    /// Sheets with ink saved for this page; the peek tab shows while this is above zero.
    @Published private(set) var savedCount = 0
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    var current: RoughSheet { sheets[min(max(0, selected), sheets.count - 1)] }

    func show(pageId: String?) {
        guard pageId != self.pageId else { return }
        flush()
        self.pageId = pageId
        let stored = pageId.map(RoughStore.load) ?? []
        sheets = stored.isEmpty ? [RoughSheet()] : stored
        selected = 0
        savedCount = stored.count
        if pageId == nil { isOpen = false }
    }

    func setInk(_ drawing: PKDrawing, sheetId: String) {
        guard let i = sheets.firstIndex(where: { $0.id == sheetId }) else { return }
        sheets[i].ink = drawing.dataRepresentation()
        sheets[i].strokes = drawing.strokes.count
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func addSheet() {
        sheets.append(RoughSheet())
        selected = sheets.count - 1
    }

    /// Deleting the only sheet clears this page's rough work and tucks the drawer away.
    func deleteSelected() {
        guard sheets.indices.contains(selected) else { return }
        sheets.remove(at: selected)
        if sheets.isEmpty {
            sheets = [RoughSheet()]
            selected = 0
            isOpen = false
        } else {
            selected = min(selected, sheets.count - 1)
        }
        dirty = true
        flush()
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, let pageId else { return }
        dirty = false
        RoughStore.save(sheets, pageId: pageId)
        savedCount = sheets.filter { !$0.isEmpty }.count
    }
}

/// Docked at the right edge: a panel when open, a little orange tab when tucked away.
@MainActor
struct RoughDrawer: View {
    @ObservedObject var model: RoughModel
    let controller: NotebookCanvasController
    let pageNumber: Int
    @State private var drag: CGFloat = 0
    @State private var confirmingDelete = false

    var body: some View {
        GeometryReader { geo in
            let width = min(max(geo.size.width * 0.4, 320), 500)
            ZStack(alignment: .trailing) {
                if model.isOpen {
                    panel(width: width)
                        .frame(height: max(320, geo.size.height - 24))
                        .offset(x: drag)
                        .padding(.trailing, 10)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if model.savedCount > 0 {
                    peek
                        .offset(y: -geo.size.height * 0.12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
        }
        .animation(Theme.Motion.soft, value: model.isOpen)
        .animation(Theme.Motion.pop, value: model.savedCount > 0)
    }

    private var peek: some View {
        Button { model.isOpen = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "pencil.and.scribble").font(.system(size: 17, weight: .semibold))
                Text("\(model.savedCount)").font(Theme.rounded(.caption, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(width: 38, height: 80)
            .background(Theme.orange, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, style: .continuous))
            .shadow(color: Theme.orange.opacity(0.3), radius: 10, x: -2, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 6).onEnded { v in
            if v.translation.width < -20 { model.isOpen = true }
        })
        .accessibilityLabel("Rough work for this page, \(model.savedCount) \(model.savedCount == 1 ? "sheet" : "sheets")")
        .accessibilityHint("Swipe left or tap to open")
        .accessibilityIdentifier("rough.peek")
    }

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag = max(0, $0.translation.width) }
            .onEnded { v in
                withAnimation(Theme.Motion.soft) {
                    if v.translation.width > 80 || v.predictedEndTranslation.width > 220 { model.isOpen = false }
                    drag = 0
                }
            }
    }

    private func panel(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Grab here (or the title) and swipe right to tuck the drawer away.
            Capsule().fill(Theme.secondaryInk.opacity(0.35)).frame(width: 5, height: 46)
                .frame(width: 20).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(closeDrag)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                header
                RoughCanvas(sheet: model.current, controller: controller) { drawing, id in
                    model.setInk(drawing, sheetId: id)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .padding(.vertical, 12).padding(.trailing, 12)
        }
        .frame(width: width)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.pad, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.pad, style: .continuous).strokeBorder(Theme.orange.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18, x: -4, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rough.panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Rough work").font(Theme.title(.headline)).foregroundStyle(Theme.ink)
                Text("Page \(pageNumber)").font(Theme.rounded(.caption, weight: .medium)).foregroundStyle(Theme.secondaryInk)
            }
            .contentShape(Rectangle())
            .gesture(closeDrag)
            Spacer(minLength: 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.sheets.enumerated()), id: \.element.id) { i, _ in
                        let on = i == model.selected
                        Button { model.selected = i } label: {
                            Text("\(i + 1)")
                                .font(Theme.rounded(.subheadline, weight: .semibold))
                                .frame(minWidth: 32, minHeight: 32)
                                .foregroundStyle(on ? Color.white : Theme.ink)
                                .background(on ? Theme.orange : Theme.surfaceRaised, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rough sheet \(i + 1)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("rough.sheet.\(i + 1)")
                    }
                    Button { model.addSheet() } label: {
                        Image(systemName: "plus").font(.subheadline.weight(.bold))
                            .frame(width: 32, height: 32)
                            .foregroundStyle(Theme.accent)
                            .background(Theme.accentSoft, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a rough sheet")
                    .accessibilityIdentifier("rough.add")
                }
            }
            .fixedSize(horizontal: model.sheets.count <= 3, vertical: false)
            Button {
                // Blank sheets go without asking; ones with ink get a confirmation.
                if model.current.isEmpty { model.deleteSelected() } else { confirmingDelete = true }
            } label: {
                Image(systemName: "trash").font(.subheadline.weight(.semibold)).frame(width: 32, height: 32)
            }
            .foregroundStyle(Theme.danger)
            .accessibilityLabel("Delete rough sheet \(model.selected + 1)")
            .accessibilityIdentifier("rough.delete")
            .confirmationDialog("Delete rough sheet \(model.selected + 1)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete sheet", role: .destructive) { model.deleteSelected() }
            } message: {
                Text("This rough work will be gone for good.")
            }
            Button { model.isOpen = false } label: {
                Image(systemName: "chevron.right.2").font(.subheadline.weight(.bold)).frame(width: 32, height: 32)
            }
            .foregroundStyle(Theme.secondaryInk)
            .accessibilityLabel("Hide rough work")
            .accessibilityIdentifier("rough.close")
        }
    }
}

/// One rough sheet's PencilKit canvas. It borrows the notebook's tool picker while it's on screen.
struct RoughCanvas: UIViewRepresentable {
    let sheet: RoughSheet
    let controller: NotebookCanvasController
    let onChange: (PKDrawing, String) -> Void

    func makeUIView(context: Context) -> RoughCanvasHost { RoughCanvasHost(controller: controller) }

    func updateUIView(_ view: RoughCanvasHost, context: Context) {
        view.onChange = onChange
        view.show(sheet)
    }

    static func dismantleUIView(_ view: RoughCanvasHost, coordinator: ()) { view.detach() }
}

final class RoughCanvasHost: UIView, PKCanvasViewDelegate {
    /// Sheets are drawn in a fixed space and scaled to the drawer's width, so ink stays put on rotation.
    static let sheetSize = CGSize(width: 500, height: 1600)

    let canvas = PKCanvasView()
    private let paper = RoughPaperView()
    private weak var controller: NotebookCanvasController?
    private var sheetId: String?
    private var loading = false
    var onChange: ((PKDrawing, String) -> Void)?

    init(controller: NotebookCanvasController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = Theme.uiDynamic(light: "#FFFFFF", dark: "#2A2927")
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.showsHorizontalScrollIndicator = false
        canvas.alwaysBounceVertical = true
        canvas.bouncesZoom = false
        canvas.contentInsetAdjustmentBehavior = .never
        paper.isUserInteractionEnabled = false
        canvas.insertSubview(paper, at: 0)
        addSubview(canvas)
        canvas.accessibilityIdentifier = "rough.canvas"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        guard bounds.width > 0 else { return }
        let size = Self.sheetSize
        let s = bounds.width / size.width
        if abs(canvas.zoomScale - s) > 0.0001 || canvas.minimumZoomScale != s {
            canvas.maximumZoomScale = max(s, canvas.maximumZoomScale)
            canvas.minimumZoomScale = s
            canvas.maximumZoomScale = s
            canvas.zoomScale = s
        }
        canvas.contentSize = CGSize(width: size.width * s, height: size.height * s)
        paper.bounds = CGRect(origin: .zero, size: size)
        paper.transform = CGAffineTransform(scaleX: s, y: s)
        paper.center = CGPoint(x: size.width * s / 2, y: size.height * s / 2)
    }

    func show(_ sheet: RoughSheet) {
        guard sheet.id != sheetId else { return }
        sheetId = sheet.id
        loading = true
        canvas.drawing = (try? PKDrawing(data: sheet.ink)) ?? PKDrawing()
        loading = false
        canvas.undoManager?.removeAllActions()
        canvas.setContentOffset(.zero, animated: false)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loading, let sheetId else { return }
        onChange?(canvasView.drawing, sheetId)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { controller?.roughCanvas = canvas } else { detach() }
    }

    func detach() {
        if controller?.roughCanvas === canvas { controller?.roughCanvas = nil }
    }
}

/// Dot-grid paper for rough work, in sheet coordinates.
final class RoughPaperView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: RoughPaperView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let dot = Theme.uiDynamic(light: "#D9D3C4", dark: "#4A4743").resolvedColor(with: traitCollection)
        ctx.setFillColor(dot.cgColor)
        let step: CGFloat = 25, r: CGFloat = 1.6
        var y = step
        while y < bounds.height {
            if y + r >= rect.minY, y - r <= rect.maxY {
                var x = step
                while x < bounds.width {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
            }
            y += step
        }
    }
}
