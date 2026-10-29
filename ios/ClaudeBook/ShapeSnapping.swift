import PencilKit
import UIKit

/// Pen settings taken from the stroke that snapped, so the clean shape looks like the user's own ink.
struct InkTemplate {
    var ink: PKInk
    var size: CGSize
    var opacity: CGFloat
    var force: CGFloat
    var azimuth: CGFloat
    var altitude: CGFloat

    init(_ stroke: PKStroke) {
        let points = Array(stroke.path)
        func median(_ values: [CGFloat], _ fallback: CGFloat) -> CGFloat {
            let sorted = values.sorted()
            return sorted.isEmpty ? fallback : sorted[sorted.count / 2]
        }
        ink = stroke.ink
        size = CGSize(width: max(1, median(points.map(\.size.width), 3)), height: max(1, median(points.map(\.size.height), 3)))
        opacity = median(points.map(\.opacity), 1) > 0 ? median(points.map(\.opacity), 1) : 1
        force = median(points.map(\.force), 1)
        azimuth = median(points.map(\.azimuth), 0)
        altitude = median(points.map(\.altitude), .pi / 2)
    }

    func strokes(for shape: SnapShape) -> [PKStroke] {
        shape.paths(width: size.width).filter { $0.count > 1 }.map { path in
            let points = path.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.004, size: size,
                              opacity: opacity, force: force, azimuth: azimuth, altitude: altitude)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
    }
}

/// Holds the drawing an undo step goes back to.
final class DrawingBox: NSObject {
    let drawing: PKDrawing
    let name: String
    init(_ drawing: PKDrawing, name: String) { self.drawing = drawing; self.name = name }
}

/// Hold-to-snap on the notebook canvas: draw a shape, keep the pencil still for half a second, and it tidies up.
/// Right after a snap the shape shows handles (corners, radius, arrow ends and middle) until the next stroke.
/// Everything stays ordinary PencilKit ink, saved and uploaded like any other handwriting.
@MainActor
final class ShapeSnapper: NSObject {
    static let accent = UIColor(hex: "#D97757")
    private static let holdDelay: Duration = .milliseconds(500)
    /// How far (in screen points) the pencil can wander and still count as holding still.
    private static let holdSlop: CGFloat = 6

    var enabled = true
    private weak var canvas: PKCanvasView?
    private let previewView = UIView()
    private let previewLayer = CAShapeLayer()
    let overlay = ShapeEditOverlay()

    private var tracking = false
    private var strokesAtStart = 0
    private var points: [CGPoint] = []
    private var holdAnchor = CGPoint.zero
    private var holdTask: Task<Void, Never>?
    private var heldShape: SnapShape?
    private var pending: (count: Int, preview: SnapShape, token: Int)?
    private var pendingToken = 0

    private struct Editing {
        var shape: SnapShape
        var template: InkTemplate
        var raw: PKStroke
        /// The shape's strokes are always the last `count` strokes of the drawing.
        var count: Int
    }
    private var editing: Editing?
    private var dragStart: (shape: SnapShape, drawing: PKDrawing)?
    /// The drawing as this snapper last left it; any other change (eraser, undo) ends editing.
    private var expected: (count: Int, last: CGRect)?

    var isDragging: Bool { dragStart != nil }
    var editingShape: SnapShape? { editing?.shape }

    func attach(to canvas: PKCanvasView, in host: UIView) {
        self.canvas = canvas
        previewView.backgroundColor = .clear
        previewView.isUserInteractionEnabled = false
        previewLayer.fillColor = nil
        previewLayer.lineCap = .round
        previewLayer.lineJoin = .round
        previewView.layer.addSublayer(previewLayer)
        canvas.addSubview(previewView)
        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(drawingGesture(_:)))

        overlay.snapper = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: canvas.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])
    }

    /// The canvas content changed size (zoom, pages added).
    func layoutContent(size: CGSize) {
        previewView.frame = CGRect(origin: .zero, size: size)
        if let editing, dragStart != nil { showInk(editing.shape) }
        layoutOverlay()
    }

    // MARK: Watching the pencil

    @objc private func drawingGesture(_ gesture: UIGestureRecognizer) {
        guard let canvas else { return }
        switch gesture.state {
        case .began:
            endEditing()
            tracking = enabled && canvas.tool is PKInkingTool
            guard tracking else { return }
            strokesAtStart = canvas.drawing.strokes.count
            points = [notebookPoint(gesture)]
            holdAnchor = gesture.location(in: overlay)
            heldShape = nil
            pending = nil
            scheduleHold()
        case .changed:
            guard tracking else { return }
            points.append(notebookPoint(gesture))
            let here = gesture.location(in: overlay)
            if here.distance(to: holdAnchor) > Self.holdSlop {
                holdAnchor = here
                if heldShape != nil { heldShape = nil; hidePreview() }
                scheduleHold()
            }
        case .ended:
            holdTask?.cancel()
            guard tracking else { return }
            tracking = false
            hidePreview()
            guard let shape = heldShape else { return }
            heldShape = nil
            pendingToken += 1
            let token = pendingToken
            pending = (strokesAtStart, shape, token)
            // PencilKit adds the stroke around the time the gesture ends; take whichever comes first.
            finishSnap()
            Task {
                self.finishSnap()
                try? await Task.sleep(for: .seconds(1.5))
                if self.pending?.token == token { self.pending = nil }
            }
        default:
            holdTask?.cancel()
            tracking = false
            heldShape = nil
            hidePreview()
        }
    }

    private func notebookPoint(_ gesture: UIGestureRecognizer) -> CGPoint {
        guard let canvas, canvas.zoomScale > 0 else { return .zero }
        let p = gesture.location(in: canvas)
        return CGPoint(x: p.x / canvas.zoomScale, y: p.y / canvas.zoomScale)
    }

    private func scheduleHold() {
        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, self.tracking, let shape = ShapeRecognizer.recognize(self.points) else { return }
            self.heldShape = shape
            self.showPreview(shape)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Called from the canvas delegate after every ink change.
    func drawingDidChange() {
        finishSnap()
        guard editing != nil, dragStart == nil, let canvas else { return }
        let strokes = canvas.drawing.strokes
        if strokes.count != expected?.count || strokes.last?.renderBounds != expected?.last { endEditing() }
    }

    private func finishSnap() {
        guard let pending, let canvas else { return }
        let strokes = canvas.drawing.strokes
        guard strokes.count == pending.count + 1, let raw = strokes.last else { return }
        self.pending = nil
        let ink = raw.path.map { $0.location.applying(raw.transform) }
        snap(raw: raw, into: ShapeRecognizer.recognize(ink) ?? pending.preview)
    }

    /// Replace the drawing's last stroke (`raw`) with the clean shape and show its handles.
    func snap(raw: PKStroke, into shape: SnapShape) {
        guard let canvas, !canvas.drawing.strokes.isEmpty else { return }
        let template = InkTemplate(raw)
        let made = template.strokes(for: shape)
        guard !made.isEmpty else { return }
        let old = canvas.drawing
        var drawing = old
        drawing.strokes.removeLast()
        drawing.strokes.append(contentsOf: made)
        editing = Editing(shape: shape, template: template, raw: raw, count: made.count)
        remember(drawing)
        replace(with: drawing, undoTo: old, name: "Snap \(shape.name)")
        layoutOverlay()
        overlay.present(animated: true)
    }

    /// CI can't hold a pencil: add a wobbly stroke and snap it the same way a held stroke would.
    func snapForTesting(_ ink: [CGPoint], color: UIColor = .black, width: CGFloat = 4) {
        guard let canvas, ink.count > 1 else { return }
        endEditing()
        let points = ink.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let raw = PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [raw])
        if let shape = ShapeRecognizer.recognize(ink) { snap(raw: raw, into: shape) }
    }

    // MARK: Editing

    /// Stop showing handles. The shape stays as it is.
    func endEditing() {
        if dragStart != nil { endDrag() }
        guard editing != nil else { return }
        editing = nil
        expected = nil
        overlay.dismiss()
    }

    /// What to save: mid-drag the shape is out of the canvas ink, so add it back in where it is now.
    func strokesForSaving(_ strokes: [PKStroke]) -> [PKStroke] {
        guard let editing, dragStart != nil else { return strokes }
        return strokes + editing.template.strokes(for: editing.shape)
    }

    /// The canvas is being rebuilt (pages added or removed): drop handles and this snapper's undo steps,
    /// which hold whole-notebook drawings in the old layout.
    func reset() {
        holdTask?.cancel()
        tracking = false
        heldShape = nil
        pending = nil
        dragStart = nil
        editing = nil
        expected = nil
        hidePreview()
        overlay.dismiss()
        canvas?.undoManager?.removeAllActions(withTarget: self)
    }

    func beginDrag() {
        guard let editing, let canvas, dragStart == nil else { return }
        let drawing = canvas.drawing
        guard drawing.strokes.count >= editing.count else { endEditing(); return }
        dragStart = (editing.shape, drawing)
        var without = drawing
        without.strokes.removeLast(editing.count)
        // While dragging, the shape is drawn live on a layer and the strokes are written once at the end.
        canvas.drawing = without
        showInk(editing.shape)
    }

    /// `translation` is in screen points from where the drag began.
    func drag(_ handle: SnapShape.Handle, by translation: CGPoint) {
        guard let start = dragStart, var editing, let canvas, canvas.zoomScale > 0 else { return }
        let delta = translation * (1 / canvas.zoomScale)
        if handle == .move {
            editing.shape = start.shape.translated(by: delta)
        } else if let origin = start.shape.handles.first(where: { $0.handle == handle })?.point {
            editing.shape = start.shape.moving(handle, to: origin + delta)
        }
        self.editing = editing
        showInk(editing.shape)
        layoutOverlay()
    }

    func endDrag() {
        guard let start = dragStart, var editing, let canvas else { dragStart = nil; return }
        dragStart = nil
        let made = editing.template.strokes(for: editing.shape)
        var drawing = canvas.drawing
        drawing.strokes.append(contentsOf: made)
        editing.count = made.count
        self.editing = editing
        remember(drawing)
        hidePreview()
        if editing.shape == start.shape {
            canvas.drawing = drawing
        } else {
            replace(with: drawing, undoTo: start.drawing, name: "Adjust \(editing.shape.name)")
        }
        layoutOverlay()
    }

    func cycleHeads() {
        guard var shape = editing?.shape, shape.isOpen else { return }
        switch shape.heads {
        case .none: shape.heads = .end
        case .end: shape.heads = .both
        case .both: shape.heads = .none; shape.halfHead = 0
        }
        replaceShape(with: shape, name: "Change arrowheads")
    }

    /// Put the original hand-drawn stroke back.
    func unsnap() {
        guard let editing, let canvas, canvas.drawing.strokes.count >= editing.count else { return }
        let old = canvas.drawing
        var drawing = old
        drawing.strokes.removeLast(editing.count)
        drawing.strokes.append(editing.raw)
        self.editing = nil
        expected = nil
        overlay.dismiss()
        replace(with: drawing, undoTo: old, name: "Unsnap shape")
    }

    private func replaceShape(with shape: SnapShape, name: String) {
        guard var editing, let canvas, canvas.drawing.strokes.count >= editing.count else { return }
        let old = canvas.drawing
        var drawing = old
        drawing.strokes.removeLast(editing.count)
        let made = editing.template.strokes(for: shape)
        drawing.strokes.append(contentsOf: made)
        editing.shape = shape
        editing.count = made.count
        self.editing = editing
        remember(drawing)
        replace(with: drawing, undoTo: old, name: name)
        layoutOverlay()
    }

    private func remember(_ drawing: PKDrawing) {
        expected = (drawing.strokes.count, drawing.strokes.last?.renderBounds ?? .null)
    }

    private func replace(with drawing: PKDrawing, undoTo old: PKDrawing, name: String) {
        guard let canvas else { return }
        if let undo = canvas.undoManager {
            undo.registerUndo(withTarget: self, selector: #selector(restore(_:)), object: DrawingBox(old, name: name))
            undo.setActionName(name)
        }
        canvas.drawing = drawing
    }

    /// Undo and redo both land here; each registers the step back the other way.
    @objc private func restore(_ box: DrawingBox) {
        guard let canvas else { return }
        endEditing()
        replace(with: box.drawing, undoTo: canvas.drawing, name: box.name)
    }

    // MARK: Showing it

    private func path(for shape: SnapShape, width: CGFloat) -> CGPath {
        let s = canvas?.zoomScale ?? 1
        let path = CGMutablePath()
        for line in shape.paths(width: width) where line.count > 1 {
            path.addLines(between: line.map { CGPoint(x: $0.x * s, y: $0.y * s) })
        }
        return path
    }

    /// The dashed outline that appears while holding, before the pencil lifts.
    private func showPreview(_ shape: SnapShape) {
        previewLayer.path = path(for: shape, width: 3)
        previewLayer.strokeColor = Self.accent.cgColor
        previewLayer.lineWidth = 2.5
        previewLayer.lineDashPattern = [7, 5]
        previewLayer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.12
        previewLayer.add(fade, forKey: "fade")
    }

    /// The shape drawn in its own ink while a handle is dragged.
    private func showInk(_ shape: SnapShape) {
        guard let canvas, let template = editing?.template else { return }
        let style = canvas.traitCollection.userInterfaceStyle
        let color = style == .dark ? PKInkingTool.convertColor(template.ink.color, from: .light, to: .dark) : template.ink.color
        previewLayer.removeAllAnimations()
        previewLayer.path = path(for: shape, width: template.size.width)
        previewLayer.strokeColor = color.cgColor
        previewLayer.lineWidth = max(1, template.size.width * 0.9 * canvas.zoomScale)
        previewLayer.lineDashPattern = nil
        previewLayer.opacity = 1
    }

    private func hidePreview() {
        previewLayer.path = nil
    }

    /// Keep the handles on the shape as the notebook scrolls and zooms.
    func layoutOverlay() {
        guard let editing, let canvas, canvas.zoomScale > 0 else { return }
        let s = canvas.zoomScale
        func screen(_ p: CGPoint) -> CGPoint { overlay.convert(CGPoint(x: p.x * s, y: p.y * s), from: canvas) }
        let b = editing.shape.bounds
        let rect = b.isNull ? .null : CGRect(origin: screen(b.origin), size: CGSize(width: b.width * s, height: b.height * s))
        overlay.layout(shape: editing.shape, handles: editing.shape.handles.map { ($0.handle, screen($0.point)) }, shapeRect: rect)
    }
}

// MARK: - Handles and toolbar

/// Sits over the canvas and takes touches only on its handles and toolbar; pencil strokes elsewhere still draw.
final class ShapeEditOverlay: UIView {
    weak var snapper: ShapeSnapper?
    private var handleViews: [ShapeHandleView] = []
    private let toolbar = ShapeToolbar()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isHidden = true
        addSubview(toolbar)
        toolbar.onMove = { [weak self] state, translation in self?.drag(.move, state: state, translation: translation) }
        toolbar.onHeads = { [weak self] in self?.snapper?.cycleHeads() }
        toolbar.onUnsnap = { [weak self] in self?.snapper?.unsnap() }
        toolbar.onDone = { [weak self] in self?.snapper?.endEditing() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        for child in subviews.reversed() where !child.isHidden {
            if let target = child.hitTest(convert(point, to: child), with: event) { return target }
        }
        return nil
    }

    func present(animated: Bool) {
        isHidden = false
        guard animated else { return }
        for view in subviews {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.68, initialSpringVelocity: 0.4) {
            for view in self.subviews { view.alpha = 1; view.transform = .identity }
        }
    }

    func dismiss() {
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.15, animations: {
            for view in self.subviews { view.alpha = 0 }
        }, completion: { _ in
            guard self.snapper?.editingShape == nil else { return }
            self.isHidden = true
            for view in self.subviews { view.alpha = 1; view.transform = .identity }
        })
        accessibilityElements = []
    }

    func layout(shape: SnapShape, handles: [(SnapShape.Handle, CGPoint)], shapeRect: CGRect) {
        if handleViews.count != handles.count {
            handleViews.forEach { $0.removeFromSuperview() }
            handleViews = handles.enumerated().map { i, entry in
                let view = ShapeHandleView(handle: entry.0, index: i)
                view.onDrag = { [weak self, weak view] state, translation in
                    guard let view else { return }
                    self?.drag(view.handle, state: state, translation: translation)
                }
                insertSubview(view, belowSubview: toolbar)
                return view
            }
        }
        for (view, entry) in zip(handleViews, handles) {
            // A line becomes an arc once bent; the same views carry on with the new roles.
            view.handle = entry.0
            view.center = entry.1
        }
        toolbar.configure(shape: shape)
        let size = toolbar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let rect = shapeRect.isNull ? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0) : shapeRect
        var y = rect.minY - 30 - size.height
        if y < 8 { y = min(bounds.height - size.height - 8, rect.maxY + 30) }
        let x = min(max(12, rect.midX - size.width / 2), max(12, bounds.width - size.width - 12))
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        var elements: [UIView] = [toolbar]
        elements += handleViews
        accessibilityElements = elements
    }

    private func drag(_ handle: SnapShape.Handle, state: UIGestureRecognizer.State, translation: CGPoint) {
        switch state {
        case .began: snapper?.beginDrag()
        case .changed: snapper?.drag(handle, by: translation)
        default: snapper?.endDrag()
        }
    }
}

final class ShapeHandleView: UIView {
    var handle: SnapShape.Handle { didSet { if handle != oldValue { describe() } } }
    var onDrag: ((UIGestureRecognizer.State, CGPoint) -> Void)?

    init(handle: SnapShape.Handle, index: Int) {
        self.handle = handle
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        backgroundColor = .clear
        let accent = ShapeSnapper.accent
        let dot = UIView()
        dot.isUserInteractionEnabled = false
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.22
        dot.layer.shadowRadius = 3
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        switch handle {
        case .move:
            dot.frame = CGRect(x: 7, y: 7, width: 30, height: 30)
            dot.backgroundColor = accent
            let icon = UIImageView(image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
            icon.tintColor = .white
            icon.frame = dot.bounds
            icon.contentMode = .center
            dot.addSubview(icon)
        case .bend:
            dot.frame = CGRect(x: 13, y: 13, width: 18, height: 18)
            dot.backgroundColor = accent
            dot.layer.borderColor = UIColor.white.cgColor
            dot.layer.borderWidth = 3
        default:
            dot.frame = CGRect(x: 11, y: 11, width: 22, height: 22)
            dot.backgroundColor = .white
            dot.layer.borderColor = accent.cgColor
            dot.layer.borderWidth = 3
        }
        dot.layer.cornerRadius = dot.bounds.width / 2
        addSubview(dot)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "shape.handle.\(index)"
        accessibilityHint = "Drag to adjust the shape"
        describe()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func describe() {
        switch handle {
        case .move: accessibilityLabel = "Move shape"
        case .bend: accessibilityLabel = "Bend"
        case .radius: accessibilityLabel = "Radius"
        case .radiusX: accessibilityLabel = "Width"
        case .radiusY: accessibilityLabel = "Height"
        case .vertex(let i): accessibilityLabel = "Point \(i + 1)"
        }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        if g.state == .began { UISelectionFeedbackGenerator().selectionChanged() }
        UIView.animate(withDuration: 0.12) {
            self.transform = g.state == .began || g.state == .changed ? CGAffineTransform(scaleX: 1.25, y: 1.25) : .identity
        }
        onDrag?(g.state, t)
    }
}

/// A small floating pill above the shape: drag to move, arrowheads, unsnap and done.
final class ShapeToolbar: UIView {
    var onMove: ((UIGestureRecognizer.State, CGPoint) -> Void)?
    var onHeads: (() -> Void)?
    var onUnsnap: (() -> Void)?
    var onDone: (() -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let stack = UIStackView()
    private let grip = UIImageView()
    private let name = UILabel()
    private let heads = UIButton(type: .system)
    private let unsnap = UIButton(type: .system)
    private let done = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let accent = ShapeSnapper.accent
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        blur.layer.cornerRadius = 22
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        let symbols = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        grip.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right", withConfiguration: symbols)
        grip.tintColor = .secondaryLabel
        grip.contentMode = .center
        grip.isUserInteractionEnabled = true
        grip.isAccessibilityElement = true
        grip.accessibilityLabel = "Move shape"
        grip.accessibilityIdentifier = "shape.move"
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(movePan(_:))))

        name.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        name.textColor = .label
        name.accessibilityIdentifier = "shape.name"

        func setup(_ button: UIButton, _ symbol: String, _ label: String, _ id: String, _ action: @escaping () -> Void) {
            button.setImage(UIImage(systemName: symbol, withConfiguration: symbols), for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = label
            button.accessibilityIdentifier = id
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        setup(heads, "arrow.right", "Arrowheads", "shape.heads") { [weak self] in self?.onHeads?() }
        setup(unsnap, "scribble", "Unsnap, keep my stroke", "shape.unsnap") { [weak self] in self?.onUnsnap?() }
        setup(done, "checkmark", "Done", "shape.done") { [weak self] in self?.onDone?() }
        done.tintColor = .white
        done.backgroundColor = accent
        done.layer.cornerRadius = 17

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [grip, name, heads, unsnap, done] as [UIView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(10, after: grip)
        stack.setCustomSpacing(8, after: name)
        blur.contentView.addSubview(stack)
        var constraints = [
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -5),
        ]
        for view in [grip, heads, unsnap, done] as [UIView] {
            constraints.append(view.widthAnchor.constraint(equalToConstant: 34))
            constraints.append(view.heightAnchor.constraint(equalToConstant: 34))
        }
        NSLayoutConstraint.activate(constraints)
        accessibilityIdentifier = "shape.toolbar"
        accessibilityElements = [grip, name, heads, unsnap, done]
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(shape: SnapShape) {
        name.text = shape.name
        heads.isHidden = !shape.isOpen
        let symbol: String
        switch shape.heads {
        case .none: symbol = "line.diagonal"
        case .end: symbol = "arrow.right"
        case .both: symbol = "arrow.left.and.right"
        }
        heads.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        heads.accessibilityValue = shape.heads == .none ? "None" : shape.heads == .end ? "One end" : "Both ends"
    }

    @objc private func movePan(_ g: UIPanGestureRecognizer) {
        onMove?(g.state, g.translation(in: superview))
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
