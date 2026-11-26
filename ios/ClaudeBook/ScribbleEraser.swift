import PencilKit
import UIKit

/// Reusable scribble-to-erase handler that attaches to any `PKCanvasView`.
///
/// When the user draws a quick back-and-forth scratch-out or steep oscillating zigzag with a
/// `PKInkingTool` that touches one or more existing strokes, both the scribble stroke and all
/// intersected strokes are removed in a single undoable step.
@MainActor
final class ScribbleEraser: NSObject {
    static let actionName = "Scribble Erase"

    var isEnabled = true
    /// Optional hook (e.g. `ShapeSnapper.hasActiveOrPendingSnap`) that suppresses scribble erasure.
    var shouldSuppress: (() -> Bool)?

    private weak var canvas: PKCanvasView?
    private var tracking = false
    private var drawingBeforeStroke: PKDrawing?
    private var pending: (before: PKDrawing, token: Int)?
    private var pendingToken = 0
    private(set) var isApplyingChange = false

    func attach(to canvas: PKCanvasView) {
        self.canvas = canvas
        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(drawingGesture(_:)))
    }

    /// Clear any in-flight gesture tracking and undo actions bound to stale canvas layouts.
    func reset() {
        tracking = false
        drawingBeforeStroke = nil
        pending = nil
        canvas?.undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: Live gesture tracking

    @objc private func drawingGesture(_ gesture: UIGestureRecognizer) {
        guard let canvas else { return }
        switch gesture.state {
        case .began:
            tracking = isEnabled && (canvas.tool is PKInkingTool)
            guard tracking else {
                drawingBeforeStroke = nil
                pending = nil
                return
            }
            drawingBeforeStroke = canvas.drawing
            pending = nil
        case .changed:
            break
        case .ended:
            guard tracking, let before = drawingBeforeStroke else {
                tracking = false
                drawingBeforeStroke = nil
                return
            }
            tracking = false
            drawingBeforeStroke = nil
            guard isEnabled, shouldSuppress?() != true else { return }
            pendingToken += 1
            let token = pendingToken
            pending = (before: before, token: token)
            _ = finishErase()
            Task { [weak self] in
                guard let self else { return }
                _ = self.finishErase()
                try? await Task.sleep(for: .seconds(1.5))
                if self.pending?.token == token { self.pending = nil }
            }
        default:
            tracking = false
            drawingBeforeStroke = nil
            pending = nil
        }
    }

    /// Called from `PKCanvasViewDelegate.canvasViewDrawingDidChange(_:)`.
    /// Returns `true` if the newly added stroke triggered a scribble erasure and replaced `canvas.drawing`.
    @discardableResult
    func drawingDidChange() -> Bool {
        guard !isApplyingChange else { return false }
        return finishErase()
    }

    @discardableResult
    private func finishErase() -> Bool {
        guard !isApplyingChange, let pending, let canvas else { return false }
        if !isEnabled || shouldSuppress?() == true {
            self.pending = nil
            return false
        }
        let current = canvas.drawing
        guard current.strokes.count == pending.before.strokes.count + 1,
              let scribbleStroke = current.strokes.last else {
            return false
        }
        self.pending = nil
        return eraseIfScribble(scribbleStroke: scribbleStroke, before: pending.before)
    }

    @discardableResult
    private func eraseIfScribble(scribbleStroke: PKStroke, before: PKDrawing) -> Bool {
        guard !before.strokes.isEmpty, Self.isScribble(scribbleStroke) else { return false }
        let hitIndices = Self.intersectedStrokeIndices(scribble: scribbleStroke, in: before.strokes)
        guard !hitIndices.isEmpty else { return false }
        let remaining = before.strokes.enumerated().compactMap { index, stroke in
            hitIndices.contains(index) ? nil : stroke
        }
        replace(with: PKDrawing(strokes: remaining), undoTo: before, name: Self.actionName)
        return true
    }

    /// Simulates a user-drawn stroke on the attached canvas (for deterministic testing and programmatic user input),
    /// applying scribble-to-erase when appropriate and registering single-step undo/redo.
    func applyUserStroke(_ stroke: PKStroke) {
        guard let canvas else { return }
        if let undo = canvas.undoManager, undo.groupingLevel > 0, !undo.isUndoing, !undo.isRedoing {
            RunLoop.current.run(until: Date())
        }
        let before = canvas.drawing
        if isEnabled, canvas.tool is PKInkingTool, shouldSuppress?() != true,
           eraseIfScribble(scribbleStroke: stroke, before: before) {
            return
        }
        let next = PKDrawing(strokes: before.strokes + [stroke])
        replace(with: next, undoTo: before, name: "Ink")
    }

    // MARK: Undo / Redo

    private func replace(with drawing: PKDrawing, undoTo old: PKDrawing, name: String) {
        guard let canvas else { return }
        isApplyingChange = true
        defer { isApplyingChange = false }
        if let undo = canvas.undoManager {
            undo.registerUndo(withTarget: self, selector: #selector(restore(_:)), object: DrawingBox(old, name: name))
            undo.setActionName(name)
        }
        canvas.drawing = drawing
    }

    @objc private func restore(_ box: DrawingBox) {
        guard let canvas else { return }
        replace(with: box.drawing, undoTo: canvas.drawing, name: box.name)
    }

    // MARK: Coordinate-space extraction & Stroke Intersection

    /// Extracts stroke sample points in canvas coordinates by applying `stroke.transform`.
    static func strokePoints(_ stroke: PKStroke) -> [CGPoint] {
        stroke.path.map { $0.location.applying(stroke.transform) }
    }

    /// Half-width radius of a stroke in canvas coordinates, accounting for `stroke.transform` scale.
    static func strokeRadius(_ stroke: PKStroke) -> CGFloat {
        let points = Array(stroke.path)
        let scaleX = hypot(stroke.transform.a, stroke.transform.c)
        let scaleY = hypot(stroke.transform.b, stroke.transform.d)
        let scale = max(0.5, (scaleX + scaleY) * 0.5)
        guard !points.isEmpty else { return 2 * scale }
        let widths = points.map { max($0.size.width, $0.size.height) }.sorted()
        let medianWidth = widths[widths.count / 2]
        return max(1.5, medianWidth * 0.5 * scale)
    }

    /// Returns indices of all strokes in `strokes` that touch or intersect `scribble`.
    static func intersectedStrokeIndices(scribble: PKStroke, in strokes: [PKStroke]) -> IndexSet {
        guard !strokes.isEmpty else { return IndexSet() }
        let scribblePts = decimatedPoints(strokePoints(scribble), minStep: 1.5)
        guard !scribblePts.isEmpty else { return IndexSet() }
        let scribbleRad = strokeRadius(scribble)
        let scribbleBox = scribble.renderBounds
        var hits = IndexSet()
        for (index, candidate) in strokes.enumerated() {
            let candidateRad = strokeRadius(candidate)
            let tolerance = scribbleRad + candidateRad + 2.5
            let expanded = scribbleBox.isNull ? .null : scribbleBox.insetBy(dx: -(tolerance + 2), dy: -(tolerance + 2))
            if !expanded.isNull, !candidate.renderBounds.isNull, !expanded.intersects(candidate.renderBounds) {
                continue
            }
            let candidatePts = decimatedPoints(strokePoints(candidate), minStep: 1.5)
            guard !candidatePts.isEmpty else { continue }
            if polylinesTouch(scribblePts, candidatePts, maxDistance: tolerance) {
                hits.insert(index)
            }
        }
        return hits
    }

    static func strokesIntersect(_ a: PKStroke, _ b: PKStroke) -> Bool {
        !intersectedStrokeIndices(scribble: a, in: [b]).isEmpty
    }

    private static func decimatedPoints(_ raw: [CGPoint], minStep: CGFloat) -> [CGPoint] {
        guard let first = raw.first else { return [] }
        var out = [first]
        for p in raw.dropFirst() where out[out.count - 1].distance(to: p) >= minStep {
            out.append(p)
        }
        if let last = raw.last, out[out.count - 1].distance(to: last) > 0.01 {
            out.append(last)
        }
        return out
    }

    private static func polylinesTouch(_ a: [CGPoint], _ b: [CGPoint], maxDistance: CGFloat) -> Bool {
        let segsA: [(CGPoint, CGPoint)] = a.count == 1 ? [(a[0], a[0])] : Array(zip(a, a.dropFirst()))
        let segsB: [(CGPoint, CGPoint)] = b.count == 1 ? [(b[0], b[0])] : Array(zip(b, b.dropFirst()))
        for (a0, a1) in segsA {
            let minAX = min(a0.x, a1.x) - maxDistance
            let maxAX = max(a0.x, a1.x) + maxDistance
            let minAY = min(a0.y, a1.y) - maxDistance
            let maxAY = max(a0.y, a1.y) + maxDistance
            for (b0, b1) in segsB {
                if max(b0.x, b1.x) < minAX || min(b0.x, b1.x) > maxAX
                    || max(b0.y, b1.y) < minAY || min(b0.y, b1.y) > maxAY {
                    continue
                }
                if segmentToSegmentDistance(a0, a1, b0, b1) <= maxDistance {
                    return true
                }
            }
        }
        return false
    }

    static func segmentToSegmentDistance(_ a0: CGPoint, _ a1: CGPoint, _ b0: CGPoint, _ b1: CGPoint) -> CGFloat {
        if segmentsProperlyIntersect(a0, a1, b0, b1) { return 0 }
        return min(
            min(Geo.segmentDistance(a0, b0, b1), Geo.segmentDistance(a1, b0, b1)),
            min(Geo.segmentDistance(b0, a0, a1), Geo.segmentDistance(b1, a0, a1))
        )
    }

    private static func segmentsProperlyIntersect(_ a0: CGPoint, _ a1: CGPoint, _ b0: CGPoint, _ b1: CGPoint) -> Bool {
        let ab = a1 - a0
        let cd = b1 - b0
        let d1 = Geo.cross(ab, b0 - a0)
        let d2 = Geo.cross(ab, b1 - a0)
        let d3 = Geo.cross(cd, a0 - b0)
        let d4 = Geo.cross(cd, a1 - b0)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    // MARK: Scribble Detection

    static func isScribble(_ stroke: PKStroke) -> Bool {
        isScribble(strokePoints(stroke))
    }

    /// Recognizes back-and-forth scratch-outs and steep oscillating sawtooth/zigzag strokes while
    /// rejecting straight lines, checkmarks, corners, arrows, closed polygons/ellipses, and tiny dots.
    static func isScribble(_ raw: [CGPoint]) -> Bool {
        var pts: [CGPoint] = []
        for p in raw where pts.last.map({ $0.distance(to: p) > 1.5 }) ?? true {
            pts.append(p)
        }
        if let last = raw.last, let prev = pts.last, prev.distance(to: last) > 0.5 {
            pts.append(last)
        }
        guard pts.count >= 4 else { return false }

        let totalLength = Geo.arcLength(pts)
        let diag = Geo.diagonal(pts)
        guard totalLength >= 45, diag >= 16 else { return false }

        let chord = pts[0].distance(to: pts[pts.count - 1])
        guard totalLength >= 1.25 * diag, totalLength >= 1.3 * chord else { return false }

        // Reject clean closed shapes (circles, ellipses, rectangles, triangles, polygons), lines, curves, and arrows.
        if let recognized = ShapeRecognizer.recognize(pts) {
            if !recognized.isOpen || recognized.heads != .none
                || recognized.kind == .line || recognized.kind == .arc || recognized.kind == .curve {
                return false
            }
        }

        // Light moving-average pass removes tiny hand tremor without rounding off real reversals.
        var smoothed = [pts[0]]
        for i in 1..<(pts.count - 1) {
            smoothed.append(CGPoint(
                x: 0.25 * pts[i - 1].x + 0.5 * pts[i].x + 0.25 * pts[i + 1].x,
                y: 0.25 * pts[i - 1].y + 0.5 * pts[i].y + 0.25 * pts[i + 1].y
            ))
        }
        smoothed.append(pts[pts.count - 1])

        let epsilon = max(3.0, min(10.0, 0.04 * diag))
        var verts = simplifyWithReversals(smoothed, epsilon: epsilon)

        // Merge nearly collinear vertices (< 25°) so gently bowed sweeps form single legs.
        var merged = true
        while merged && verts.count > 2 {
            merged = false
            for i in 1..<(verts.count - 1) {
                if Geo.turn(verts[i - 1], verts[i], verts[i + 1]) < 25 {
                    verts.remove(at: i)
                    merged = true
                    break
                }
            }
        }

        struct Leg {
            var length: CGFloat
            var dir: CGPoint
        }
        var allLegs: [Leg] = []
        var maxLeg: CGFloat = 0
        for i in 1..<verts.count {
            let delta = verts[i] - verts[i - 1]
            let len = delta.length
            guard len > 1e-4 else { continue }
            if len > maxLeg { maxLeg = len }
            allLegs.append(Leg(length: len, dir: delta * (1 / len)))
        }

        // Filter out short turnaround bridges or tiny arrow barbs so only real stroke sweeps count.
        let minLeg = max(8.0, max(0.12 * diag, 0.20 * maxLeg))
        let legs = allLegs.filter { $0.length >= minLeg }
        guard legs.count >= 4 else { return false }

        struct Transition {
            var angle: CGFloat
            var crossZ: CGFloat
        }
        var transitions: [Transition] = []
        for i in 1..<legs.count {
            let u = legs[i - 1].dir
            let v = legs[i].dir
            let angle = acos(max(-1, min(1, Geo.dot(u, v)))) * 180 / .pi
            let crossZ = Geo.cross(u, v)
            transitions.append(Transition(angle: angle, crossZ: crossZ))
        }

        var reversals = 0
        for i in transitions.indices {
            let t = transitions[i]
            if t.angle >= 130 {
                // Tight ~180° fold-back scratch-out reversal.
                reversals += 1
            } else if t.angle >= 80 {
                // Steep sawtooth corner: must alternate turn direction with a neighboring turn
                // (rejecting rectangles, spirals, and polygons whose corners wind monotonically).
                let prevAlternates = i > 0
                    && transitions[i - 1].angle >= 80
                    && (t.crossZ * transitions[i - 1].crossZ < 0 || transitions[i - 1].angle >= 130)
                let nextAlternates = i + 1 < transitions.count
                    && transitions[i + 1].angle >= 80
                    && (t.crossZ * transitions[i + 1].crossZ < 0 || transitions[i + 1].angle >= 130)
                if prevAlternates || nextAlternates {
                    reversals += 1
                }
            }
        }
        return reversals >= 3
    }

    /// Ramer-Douglas-Peucker simplification extended to preserve collinear ~180° fold-back reversals
    /// that lie directly along the segment between `p.first` and `p.last`.
    private static func simplifyWithReversals(_ p: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard p.count > 2 else { return p }
        let a = p[0]
        let b = p[p.count - 1]
        let abLen = a.distance(to: b)

        var farthestIndex = 0
        var farthestDistance: CGFloat = -1
        for i in 1..<(p.count - 1) {
            let d = Geo.segmentDistance(p[i], a, b)
            if d > farthestDistance {
                farthestDistance = d
                farthestIndex = i
            }
        }
        if farthestDistance > epsilon {
            let left = simplifyWithReversals(Array(p[...farthestIndex]), epsilon: epsilon)
            let right = simplifyWithReversals(Array(p[farthestIndex...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }

        if abLen > epsilon {
            let u = (b - a) * (1 / abLen)
            var peakProj: CGFloat = 0
            var peakIndex = 0
            var maxBacktrack: CGFloat = 0
            var splitIndex = 0
            for i in 1..<(p.count - 1) {
                let proj = Geo.dot(p[i] - a, u)
                if proj > peakProj {
                    peakProj = proj
                    peakIndex = i
                }
                if peakProj - proj > maxBacktrack {
                    maxBacktrack = peakProj - proj
                    splitIndex = peakIndex
                }
            }
            if maxBacktrack > epsilon * 2, splitIndex > 0, splitIndex < p.count - 1 {
                let left = simplifyWithReversals(Array(p[...splitIndex]), epsilon: epsilon)
                let right = simplifyWithReversals(Array(p[splitIndex...]), epsilon: epsilon)
                return Array(left.dropLast()) + right
            }
        }

        return [a, b]
    }
}
