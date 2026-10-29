import CoreGraphics
import Foundation

/// A hand-drawn stroke tidied into a clean shape, GoodNotes style: draw, keep the pencil down for a moment, and
/// the stroke snaps. Plain geometry in notebook units (the same units as the ink), so it is testable without PencilKit.
/// The result is turned back into ordinary pen strokes, so Claude and ChatGPT see it like any other handwriting.
struct SnapShape: Equatable {
    enum Kind: Equatable { case line, curve, arc, spline, polyline, ellipse, polygon }
    /// What stays true while the shape is edited.
    enum Fit: Equatable { case free, circle, rectangle, regular }
    enum Heads: Equatable { case none, end, both }
    enum Handle: Equatable { case vertex(Int), bend, radius, radiusX, radiusY, move }

    var kind: Kind
    /// line: ends. curve and arc: start, a point on the curve, end. spline and polyline: on-curve points.
    /// polygon: corners. ellipse: the center.
    var points: [CGPoint]
    var radii: CGSize = .zero
    var rotation: CGFloat = 0
    var fit: Fit = .free
    var heads: Heads = .none
    /// 0 draws full arrowheads. 1 or -1 draws a single barb on that side, a fishhook for one-electron moves.
    var halfHead: Int = 0

    var isOpen: Bool { kind != .ellipse && kind != .polygon }

    var name: String {
        let arrow = heads != .none
        switch kind {
        case .line:
            if !arrow { return "Line" }
            return heads == .both ? "Double arrow" : halfHead != 0 ? "Fishhook arrow" : "Arrow"
        case .curve, .arc, .spline:
            if !arrow { return kind == .arc ? "Arc" : "Curve" }
            return heads == .both ? "Curved double arrow" : halfHead != 0 ? "Fishhook arrow" : "Curved arrow"
        case .polyline:
            if arrow { return "Bent arrow" }
            return points.count == 3 ? "Corner" : "Zigzag"
        case .ellipse:
            return fit == .circle ? "Circle" : "Ellipse"
        case .polygon:
            switch points.count {
            case 3: return fit == .regular ? "Equilateral triangle" : "Triangle"
            case 4:
                guard fit == .rectangle else { return "Quadrilateral" }
                let w = points[0].distance(to: points[1]), h = points[1].distance(to: points[2])
                return abs(w - h) < 0.5 ? "Square" : "Rectangle"
            case 5: return "Pentagon"
            case 6: return "Hexagon"
            case 7: return "Heptagon"
            case 8: return "Octagon"
            default: return "Polygon"
            }
        }
    }

    // MARK: Drawing

    /// The shape as pen paths: the outline first, then any arrowheads. `width` is the pen width, which sizes the heads.
    func paths(width: CGFloat) -> [[CGPoint]] {
        let main = outline()
        guard heads != .none, isOpen, main.count > 1 else { return [main] }
        var out = [main]
        let length = Geo.arcLength(main)
        let head = min(max(12, width * 4.5), 0.35 * length)
        out.append(arrowhead(along: Array(main.reversed()), length: head))
        if heads == .both { out.append(arrowhead(along: main, length: head)) }
        return out
    }

    func outline() -> [CGPoint] {
        switch kind {
        case .line: return Geo.densify(points, closed: false)
        case .polyline: return Geo.densify(points, closed: false)
        case .polygon: return Geo.densify(points, closed: true)
        case .curve: return Geo.sampleQuad(points[0], points[1], points[2], count: sampleCount)
        case .arc: return Geo.sampleArc(points[0], points[1], points[2], count: sampleCount)
        case .spline: return Geo.sampleSpline(points, perSegment: max(8, sampleCount / max(1, points.count - 1)))
        case .ellipse:
            let rx = radii.width, ry = radii.height
            let perimeter = 2 * CGFloat.pi * sqrt((rx * rx + ry * ry) / 2)
            let n = max(48, Int(perimeter / 2.5))
            return (0...n).map { i in
                let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(n)
                return points[0] + Geo.rotate(CGPoint(x: rx * cos(t), y: ry * sin(t)), by: rotation)
            }
        }
    }

    private var sampleCount: Int {
        let rough = Geo.arcLength(points)
        return min(400, max(32, Int(rough * 1.6 / 2.5)))
    }

    /// `path` runs from the tip backwards. Full heads are one V stroke; a fishhook is a single barb.
    private func arrowhead(along path: [CGPoint], length: CGFloat) -> [CGPoint] {
        let tip = path[0]
        var back = path[path.count - 1]
        var travelled: CGFloat = 0
        for i in 1..<path.count {
            travelled += path[i - 1].distance(to: path[i])
            if travelled >= length * 0.6 { back = path[i]; break }
        }
        let dir = (tip - back).normalized
        let spread = 27 * CGFloat.pi / 180
        let b1 = tip + Geo.rotate(dir * -length, by: spread)
        let b2 = tip + Geo.rotate(dir * -length, by: -spread)
        if halfHead != 0 {
            let side = Geo.cross(dir, b1 - tip) * CGFloat(halfHead) > 0 ? b1 : b2
            return Geo.densify([tip, side], closed: false)
        }
        return Geo.densify([b1, tip, b2], closed: false)
    }

    var bounds: CGRect {
        let pts = outline()
        guard let first = pts.first else { return .null }
        return pts.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    // MARK: Editing

    var handles: [(handle: Handle, point: CGPoint)] {
        switch kind {
        case .line:
            return [(.vertex(0), points[0]), (.bend, (points[0] + points[1]) * 0.5), (.vertex(1), points[1])]
        case .curve, .arc:
            return [(.vertex(0), points[0]), (.bend, points[1]), (.vertex(2), points[2])]
        case .spline, .polyline:
            return points.indices.map { (handle: Handle.vertex($0), point: points[$0]) }
        case .polygon:
            var all = points.indices.map { (handle: Handle.vertex($0), point: points[$0]) }
            all.append((handle: .move, point: Geo.centroid(points)))
            return all
        case .ellipse:
            let c = points[0]
            if fit == .circle { return [(.move, c), (.radius, c + Geo.rotate(CGPoint(x: radii.width, y: 0), by: rotation))] }
            return [(.move, c),
                    (.radiusX, c + Geo.rotate(CGPoint(x: radii.width, y: 0), by: rotation)),
                    (.radiusY, c + Geo.rotate(CGPoint(x: 0, y: radii.height), by: rotation))]
        }
    }

    func translated(by d: CGPoint) -> SnapShape {
        var s = self
        s.points = points.map { $0 + d }
        return s
    }

    /// The shape after dragging one of its handles to `p`, keeping its fit (a circle stays round, a rectangle square-cornered).
    func moving(_ handle: Handle, to p: CGPoint) -> SnapShape {
        var s = self
        switch (kind, handle) {
        case (_, .move):
            let from = handles.first { $0.handle == .move }?.point ?? Geo.centroid(points)
            return translated(by: p - from)
        case (.line, .bend):
            // Pulling the middle of a line bends it into an arc through that point.
            guard Geo.segmentDistance(p, points[0], points[1]) > 2 else { return self }
            s.kind = .arc
            s.points = [points[0], p, points[1]]
        case (.line, .vertex(let i)):
            s.points[i] = p
        case (.curve, .bend), (.arc, .bend):
            s.points[1] = p
        case (.curve, .vertex(let i)), (.arc, .vertex(let i)), (.spline, .vertex(let i)):
            if i == 0 || i == points.count - 1 {
                // Moving an end carries the rest of the curve along, so the bend keeps its shape.
                let fixed = i == 0 ? points[points.count - 1] : points[0]
                s.points = points.map { Geo.similarity($0, from: (points[i], fixed), to: (p, fixed)) }
            }
            s.points[i] = p
        case (.polyline, .vertex(let i)):
            s.points[i] = p
        case (.polygon, .vertex(let i)):
            switch fit {
            case .rectangle: s.points = Geo.resizeRectangle(points, corner: i, to: p)
            case .regular:
                let c = Geo.centroid(points)
                guard p.distance(to: c) > 4 else { return self }
                s.points = points.map { Geo.similarity($0, from: (points[i], c), to: (p, c)) }
            default: s.points[i] = p
            }
        case (.ellipse, .radius):
            let r = max(3, p.distance(to: points[0]))
            s.radii = CGSize(width: r, height: r)
        case (.ellipse, .radiusX):
            let v = p - points[0]
            s.radii.width = max(3, v.length)
            s.rotation = atan2(v.y, v.x)
        case (.ellipse, .radiusY):
            let axis = Geo.rotate(CGPoint(x: 0, y: 1), by: rotation)
            s.radii.height = max(3, abs(Geo.dot(p - points[0], axis)))
        default:
            return self
        }
        return s
    }
}

// MARK: - Recognition

enum ShapeRecognizer {
    /// The clean shape a stroke was meant to be, or nil for writing and scribbles.
    static func recognize(_ raw: [CGPoint]) -> SnapShape? {
        var pts: [CGPoint] = []
        for p in raw where pts.last.map({ $0.distance(to: p) > 0.5 }) ?? true { pts.append(p) }
        guard pts.count >= 2 else { return nil }
        let length = Geo.arcLength(pts)
        let r = Geo.resample(pts, count: 128)
        let size = Geo.diagonal(r)
        guard length >= 20, size >= 16 else { return nil }
        if r[0].distance(to: r[r.count - 1]) < 0.13 * length && size > 0.15 * length {
            return closedShape(r, length: length)
        }
        if let arrow = arrow(r, length: length) { return arrow }
        return openShape(r, length: length).map(tidy)
    }

    // MARK: Open strokes

    /// Line, arc, quadratic curve, sharp-cornered polyline, or failing those a smooth spline through the stroke.
    static func openShape(_ r: [CGPoint], length: CGFloat) -> SnapShape? {
        let a = r[0], b = r[r.count - 1]
        let chord = a.distance(to: b)
        let lineError = r.reduce(CGFloat(0)) { $0 + Geo.segmentDistance($1, a, b) } / CGFloat(r.count)
        if chord > 0, lineError < 0.025 * chord, length < 1.12 * chord {
            return SnapShape(kind: .line, points: [a, b])
        }
        let m = r[r.count / 2]
        let size = max(chord, Geo.diagonal(r))
        // A shaky hand adds length without changing the shape, so compare against the smoothed stroke.
        let steady = Geo.arcLength(Geo.smooth(r))
        func fits(_ error: CGFloat, _ samples: [CGPoint]) -> Bool {
            error < 0.03 * size && abs(Geo.arcLength(samples) - steady) < 0.15 * steady
        }
        let quad = Geo.sampleQuad(a, m, b, count: 64)
        let arc = Geo.sampleArc(a, m, b, count: 64)
        var candidates: [(error: CGFloat, shape: SnapShape, samples: [CGPoint])] = [
            (Geo.curveError(r, quad), SnapShape(kind: .curve, points: [a, m, b]), quad),
            (Geo.curveError(r, arc), SnapShape(kind: .arc, points: [a, m, b]), arc),
        ]
        var verts = Geo.cleanVertices(Geo.rdp(r, epsilon: max(0.035 * length, 2)), closed: false, minTurn: 25)
        if verts.count > 2, let sharp = Geo.sharpen(r, verts, closed: false), sharp.count > 2, sharp.count <= 14,
           Geo.straightSegments(r, sharp) {
            verts = sharp
            // Favour corners when they were clearly drawn.
            candidates.append((Geo.polylineError(r, verts, closed: false) * 0.8, SnapShape(kind: .polyline, points: verts), verts))
        }
        for c in candidates.sorted(by: { $0.error < $1.error }) where fits(c.error, c.samples) { return c.shape }
        for n in [5, 7] {
            let knots = (0..<n).map { r[Int((CGFloat($0) * CGFloat(r.count - 1) / CGFloat(n - 1)).rounded())] }
            let samples = Geo.sampleSpline(knots, perSegment: 16)
            if fits(Geo.curveError(r, samples) * 1.2, samples) { return SnapShape(kind: .spline, points: knots) }
        }
        return nil
    }

    /// A stroke that runs out to a tip and then doubles back in a short V (or one barb) is an arrow.
    static func arrow(_ r: [CGPoint], length: CGFloat) -> SnapShape? {
        let n = r.count
        var s: [CGFloat] = [0]
        for i in 1..<n { s.append(s[i - 1] + r[i - 1].distance(to: r[i])) }
        let k = max(2, Int(0.025 * CGFloat(n - 1)))
        // The first sharp turn past the middle is the tip; barbs turn again later.
        var best: (turn: CGFloat, index: Int)?
        for i in k..<(n - k) where s[i] >= 0.45 * length && s[i] <= 0.97 * length {
            let t = Geo.turn(r[i - k], r[i], r[i + k])
            if let current = best {
                if i - current.index > k { break }
                if t > current.turn { best = (t, i) }
            } else if t >= 100 {
                best = (t, i)
            }
        }
        guard let tipIndex = best?.index else { return nil }
        // A zigzag turns this sharply before the tip too; an arrow's shaft doesn't.
        if tipIndex - k > k, (k..<(tipIndex - k)).contains(where: { Geo.turn(r[$0 - k], r[$0], r[$0 + k]) >= 100 }) { return nil }
        let tip = r[tipIndex]
        let headPoints = Array(r[tipIndex...])
        let chord = r[0].distance(to: tip)
        let extent = headPoints.map { $0.distance(to: tip) }.max() ?? 0
        guard extent > 0.04 * chord, extent < 0.5 * chord else { return nil }
        let dir = (tip - r[max(0, tipIndex - 3 * k)]).normalized
        let back = headPoints.reduce(CGFloat(0)) { $0 + Geo.dot($1 - tip, dir) } / CGFloat(headPoints.count)
        guard back < -0.02 * extent else { return nil }
        // A full head goes out to one barb, back to the tip and out again; a fishhook goes out once.
        var phase = 0
        for q in headPoints {
            let d = q.distance(to: tip)
            if phase == 0 && d > 0.6 * extent { phase = 1 }
            else if phase == 1 && d < 0.35 * extent { phase = 2 }
            else if phase == 2 && d > 0.6 * extent { phase = 3; break }
        }
        let full = phase == 3
        let barb = headPoints.max { $0.distance(to: tip) < $1.distance(to: tip) } ?? tip
        let shaft = Geo.resample(Array(r[...tipIndex]), count: 96)
        guard var shape = openShape(shaft, length: Geo.arcLength(shaft)).map(tidy) else { return nil }
        shape.heads = .end
        shape.halfHead = full ? 0 : (Geo.cross(dir, barb - tip) > 0 ? 1 : -1)
        return shape
    }

    // MARK: Closed strokes

    static func closedShape(_ r: [CGPoint], length: CGFloat) -> SnapShape? {
        let ellipse = fitEllipse(r)
        let diag = Geo.diagonal(r)
        let c = Geo.centroid(r)
        // Start the corner search at the point farthest from the middle, which is nearly always a corner.
        let far = r.indices.max { r[$0].distance(to: c) < r[$1].distance(to: c) } ?? 0
        let loop = far == 0 ? r : Array(r[far...]) + Array(r[1...far])
        var verts = Array(Geo.rdp(loop, epsilon: max(0.04 * diag, 2)).dropLast())
        verts = Geo.cleanVertices(verts, closed: true, minTurn: 28, minEdge: 0.05 * length)
        let sharp = verts.count >= 3 ? Geo.sharpen(Array(r.dropLast()), verts, closed: true) : nil
        let polygonError = sharp.map { Geo.polylineError(r, $0, closed: true) / (diag / 2.83) } ?? 9
        if let sharp, (3...8).contains(sharp.count), polygonError < 0.9 * (ellipse?.error ?? 9), polygonError < 0.09 {
            return tidy(SnapShape(kind: .polygon, points: sharp))
        }
        if let e = ellipse, e.error < 0.13 { return tidy(e.shape) }
        return nil
    }

    static func fitEllipse(_ r: [CGPoint]) -> (shape: SnapShape, error: CGFloat)? {
        let n = CGFloat(r.count)
        let c = Geo.centroid(r)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in r { sxx += (p.x - c.x) * (p.x - c.x); syy += (p.y - c.y) * (p.y - c.y); sxy += (p.x - c.x) * (p.y - c.y) }
        let theta = 0.5 * atan2(2 * sxy / n, (sxx - syy) / n)
        let local = r.map { Geo.rotate($0 - c, by: -theta) }
        let us = local.map(\.x), vs = local.map(\.y)
        guard let umin = us.min(), let umax = us.max(), let vmin = vs.min(), let vmax = vs.max() else { return nil }
        let u0 = (umax + umin) / 2, v0 = (vmax + vmin) / 2
        // Average the extent with an RMS estimate, so a single overshoot doesn't inflate the ellipse.
        var su: CGFloat = 0, sv: CGFloat = 0
        for q in local { su += (q.x - u0) * (q.x - u0); sv += (q.y - v0) * (q.y - v0) }
        let a = ((umax - umin) / 2 + sqrt(2 * su / n)) / 2
        let b = ((vmax - vmin) / 2 + sqrt(2 * sv / n)) / 2
        guard a > 1, b > 1 else { return nil }
        var error: CGFloat = 0
        for q in local {
            let du = (q.x - u0) / a, dv = (q.y - v0) / b
            error += abs(sqrt(du * du + dv * dv) - 1)
        }
        error /= n
        let center = c + Geo.rotate(CGPoint(x: u0, y: v0), by: theta)
        return (SnapShape(kind: .ellipse, points: [center], radii: CGSize(width: a, height: b), rotation: theta), error)
    }

    // MARK: Tidying

    /// Small corrections people expect: near-round becomes a circle, near-square corners become a rectangle,
    /// even polygons (a benzene ring) become regular, and nearly level or upright edges become exact.
    static func tidy(_ shape: SnapShape) -> SnapShape {
        var s = shape
        switch s.kind {
        case .ellipse:
            let a = s.radii.width, b = s.radii.height
            if min(a, b) / max(a, b) > 0.82 {
                s.fit = .circle
                s.radii = CGSize(width: (a + b) / 2, height: (a + b) / 2)
                s.rotation = 0
            } else {
                s.rotation = Geo.snapAngle(s.rotation, step: .pi / 2, tolerance: 8)
            }
        case .polygon:
            if s.points.count == 4, let rect = Geo.rectangle(from: s.points) {
                s.points = rect
                s.fit = .rectangle
            } else if let regular = Geo.regularPolygon(from: s.points) {
                s.points = regular
                s.fit = .regular
            } else {
                s.points = Geo.levelEdges(s.points, closed: true)
            }
        case .line, .polyline:
            s.points = Geo.levelEdges(s.points, closed: false)
        case .curve, .arc, .spline:
            break
        }
        return s
    }
}

// MARK: - Geometry

enum Geo {
    static func arcLength(_ p: [CGPoint]) -> CGFloat {
        guard p.count > 1 else { return 0 }
        return (1..<p.count).reduce(CGFloat(0)) { $0 + p[$1 - 1].distance(to: p[$1]) }
    }

    static func diagonal(_ p: [CGPoint]) -> CGFloat {
        guard let minX = p.map(\.x).min(), let maxX = p.map(\.x).max(),
              let minY = p.map(\.y).min(), let maxY = p.map(\.y).max() else { return 0 }
        return CGPoint(x: maxX - minX, y: maxY - minY).length
    }

    static func centroid(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        var sum = CGPoint.zero
        for q in p { sum = sum + q }
        return sum * (1 / CGFloat(p.count))
    }

    static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    static func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.y - a.y * b.x }

    static func rotate(_ v: CGPoint, by a: CGFloat) -> CGPoint {
        CGPoint(x: v.x * cos(a) - v.y * sin(a), y: v.x * sin(a) + v.y * cos(a))
    }

    /// Turning angle at b in degrees: 0 for straight on, 180 for a full reversal.
    static func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let u = (b - a).normalized, v = (c - b).normalized
        return acos(max(-1, min(1, dot(u, v)))) * 180 / .pi
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let l2 = dot(ab, ab)
        guard l2 > 1e-9 else { return p.distance(to: a) }
        let t = max(0, min(1, dot(p - a, ab) / l2))
        return p.distance(to: a + ab * t)
    }

    /// Evenly spaced points along a polyline, ending exactly on its last point.
    static func resample(_ p: [CGPoint], count n: Int) -> [CGPoint] {
        let total = arcLength(p)
        guard total > 0, p.count > 1 else { return Array(repeating: p.first ?? .zero, count: n) }
        let step = total / CGFloat(n - 1)
        var out = [p[0]]
        var prev = p[0], acc: CGFloat = 0, j = 1
        while j < p.count && out.count < n {
            let d = prev.distance(to: p[j])
            if acc + d >= step && d > 0 {
                let q = prev + (p[j] - prev) * ((step - acc) / d)
                out.append(q); prev = q; acc = 0
            } else {
                acc += d; prev = p[j]; j += 1
            }
        }
        while out.count < n { out.append(p[p.count - 1]) }
        out[n - 1] = p[p.count - 1]
        return out
    }

    /// Ramer-Douglas-Peucker simplification: the corners of a polyline.
    static func rdp(_ p: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard p.count > 2 else { return p }
        let a = p[0], b = p[p.count - 1]
        var index = 0, farthest: CGFloat = -1
        for i in 1..<(p.count - 1) {
            let d = segmentDistance(p[i], a, b)
            if d > farthest { farthest = d; index = i }
        }
        guard farthest > epsilon else { return [a, b] }
        let left = rdp(Array(p[...index]), epsilon: epsilon)
        let right = rdp(Array(p[index...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    /// Drop corners that barely turn or sit on a stub of an edge, softest first.
    static func cleanVertices(_ v: [CGPoint], closed: Bool, minTurn: CGFloat, minEdge: CGFloat = 0) -> [CGPoint] {
        var v = v
        while v.count > (closed ? 3 : 2) {
            let n = v.count
            var worst: (turn: CGFloat, index: Int)?
            for i in (closed ? 0 : 1)..<(closed ? n : n - 1) {
                let a = v[(i + n - 1) % n], b = v[i], c = v[(i + 1) % n]
                let t = turn(a, b, c)
                guard t < minTurn || min(a.distance(to: b), b.distance(to: c)) < minEdge else { continue }
                if worst == nil || t < worst!.turn { worst = (t, i) }
            }
            guard let worst else { break }
            v.remove(at: worst.index)
        }
        return v
    }

    /// How sharply the stroke itself turns at each corner, measured over a short stretch of ink.
    static func localTurns(_ r: [CGPoint], _ verts: [CGPoint], closed: Bool) -> [CGFloat] {
        let n = r.count
        let k = max(2, Int((0.03 * CGFloat(n - 1)).rounded()))
        return verts.map { v in
            let i = r.indices.min { r[$0].distance(to: v) < r[$1].distance(to: v) } ?? 0
            let a = closed ? r[(i - k + n) % n] : r[max(0, i - k)]
            let c = closed ? r[(i + k) % n] : r[min(n - 1, i + k)]
            return turn(a, r[i], c)
        }
    }

    /// Simplification puts corners slightly off where the pen turned; move each to the sharpest nearby point.
    static func snapCorners(_ r: [CGPoint], _ verts: [CGPoint], closed: Bool) -> [CGPoint] {
        let n = r.count
        let k = max(2, Int((0.03 * CGFloat(n - 1)).rounded()))
        let window = max(2, Int((1.5 * CGFloat(k)).rounded()))
        func sharpness(_ i: Int) -> CGFloat {
            if closed { return turn(r[(i - k + n) % n], r[i], r[(i + k) % n]) }
            guard i - k >= 0, i + k < n else { return 0 }
            return turn(r[i - k], r[i], r[i + k])
        }
        let inner = closed ? verts : Array(verts.dropFirst().dropLast())
        var moved: [CGPoint] = []
        for v in inner {
            let i = r.indices.min { r[$0].distance(to: v) < r[$1].distance(to: v) } ?? 0
            let nearby = (i - window...i + window).compactMap { j -> Int? in
                closed ? (j % n + n) % n : (j >= 0 && j < n ? j : nil)
            }
            let best = nearby.max { sharpness($0) < sharpness($1) } ?? i
            if moved.last.map({ $0.distance(to: r[best]) > 1e-6 }) ?? true { moved.append(r[best]) }
        }
        if closed, moved.count > 1, moved[0].distance(to: moved[moved.count - 1]) < 1e-6 { moved.removeLast() }
        return closed ? moved : [verts[0]] + moved + [verts[verts.count - 1]]
    }

    /// Keep only corners the pen really turned at. Nil when the stroke was a smooth curve after all.
    static func sharpen(_ r: [CGPoint], _ drawnVerts: [CGPoint], closed: Bool) -> [CGPoint]? {
        let verts = snapCorners(r, drawnVerts, closed: closed)
        guard verts.count >= (closed ? 3 : 2) else { return nil }
        let inner = closed ? verts : Array(verts.dropFirst().dropLast())
        let turns = localTurns(r, inner, closed: closed)
        let keep = zip(inner, turns).filter { $0.1 >= 22 }.map { $0.0 }
        if closed && keep.count < 3 { return nil }
        if !closed && keep.isEmpty { return nil }
        var out = closed ? keep : [verts[0]] + keep + [verts[verts.count - 1]]
        if out.count != verts.count { out = cleanVertices(out, closed: closed, minTurn: 28) }
        let corners = closed ? out : Array(out.dropFirst().dropLast())
        guard !corners.isEmpty else { return nil }
        let local = localTurns(r, corners, closed: closed)
        let n = out.count
        let drawn = (closed ? Array(0..<n) : Array(1..<(n - 1))).map { turn(out[($0 + n - 1) % n], out[$0], out[($0 + 1) % n]) }
        let meanLocal = local.reduce(0, +) / CGFloat(local.count)
        let meanDrawn = drawn.reduce(0, +) / CGFloat(drawn.count)
        return meanLocal >= max(32, 0.5 * meanDrawn) ? out : nil
    }

    /// No edge of a polyline may bow away from the (smoothed) ink.
    static func straightSegments(_ raw: [CGPoint], _ verts: [CGPoint]) -> Bool {
        let r = smooth(raw)
        let segments = Array(zip(verts, verts.dropFirst()))
        for (a, b) in segments {
            let len = a.distance(to: b)
            var worst: CGFloat = 0
            for q in r where min(q.distance(to: a), q.distance(to: b)) > 0.15 * len {
                let d = segmentDistance(q, a, b)
                if segments.allSatisfy({ d <= segmentDistance(q, $0.0, $0.1) }) { worst = max(worst, d) }
            }
            if worst > max(6.5, 0.1 * len) { return false }
        }
        return true
    }

    /// A moving average over a few neighbours, ends kept, to take out hand tremor.
    static func smooth(_ r: [CGPoint], radius: Int = 2) -> [CGPoint] {
        guard r.count > 2 else { return r }
        var out = [r[0]]
        for i in 1..<(r.count - 1) {
            let h = min(radius, i, r.count - 1 - i)
            var sum = CGPoint.zero
            for j in (i - h)...(i + h) { sum = sum + r[j] }
            out.append(sum * (1 / CGFloat(2 * h + 1)))
        }
        out.append(r[r.count - 1])
        return out
    }

    static func polylineError(_ r: [CGPoint], _ verts: [CGPoint], closed: Bool) -> CGFloat {
        var segments = Array(zip(verts, verts.dropFirst()))
        if closed, let first = verts.first, let last = verts.last { segments.append((last, first)) }
        guard !segments.isEmpty else { return .infinity }
        var total: CGFloat = 0
        for q in r { total += segments.map { segmentDistance(q, $0.0, $0.1) }.min() ?? 0 }
        return total / CGFloat(r.count)
    }

    static func curveError(_ r: [CGPoint], _ samples: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for q in r { total += samples.map { q.distance(to: $0) }.min() ?? 0 }
        return total / CGFloat(r.count)
    }

    // MARK: Curves

    /// The quadratic Bezier from a to b that passes through m halfway along.
    static func sampleQuad(_ a: CGPoint, _ m: CGPoint, _ b: CGPoint, count n: Int) -> [CGPoint] {
        let c: CGPoint = m * 2 - (a + b) * 0.5
        return (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n - 1), u = 1 - t
            let start: CGPoint = a * (u * u), middle: CGPoint = c * (2 * u * t)
            return start + middle + b * (t * t)
        }
    }

    static func circumcircle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> (center: CGPoint, radius: CGFloat)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-6 else { return nil }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
        let center = CGPoint(x: (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
                             y: (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
        let radius = center.distance(to: a)
        // A nearly straight arc has a huge circle; treat it as a line.
        guard radius < 1e5 else { return nil }
        return (center, radius)
    }

    /// The circular arc from a to b through m.
    static func sampleArc(_ a: CGPoint, _ m: CGPoint, _ b: CGPoint, count n: Int) -> [CGPoint] {
        guard let (o, r) = circumcircle(a, m, b) else { return densify([a, b], closed: false) }
        let t0 = atan2(a.y - o.y, a.x - o.x), tm = atan2(m.y - o.y, m.x - o.x), t1 = atan2(b.y - o.y, b.x - o.x)
        func ccw(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let d = (y - x).truncatingRemainder(dividingBy: 2 * .pi)
            return d < 0 ? d + 2 * .pi : d
        }
        var sweep = ccw(t0, t1)
        if ccw(t0, tm) > sweep { sweep -= 2 * .pi }
        return (0..<n).map { i in
            let t = t0 + sweep * CGFloat(i) / CGFloat(n - 1)
            return CGPoint(x: o.x + r * cos(t), y: o.y + r * sin(t))
        }
    }

    /// A Catmull-Rom spline through every point.
    static func sampleSpline(_ p: [CGPoint], perSegment: Int) -> [CGPoint] {
        guard p.count > 2 else { return densify(p, closed: false) }
        let ext = [p[0] * 2 - p[1]] + p + [p[p.count - 1] * 2 - p[p.count - 2]]
        var out: [CGPoint] = []
        for i in 1..<(ext.count - 2) {
            let p0 = ext[i - 1], p1 = ext[i], p2 = ext[i + 1], p3 = ext[i + 2]
            for j in 0..<perSegment {
                let t = CGFloat(j) / CGFloat(perSegment), t2 = t * t, t3 = t2 * t
                let a: CGPoint = p1 * 2
                let b: CGPoint = (p2 - p0) * t
                var c: CGPoint = p0 * 2 - p1 * 5
                c = (c + p2 * 4 - p3) * t2
                var d: CGPoint = p1 * 3 - p0
                d = (d - p2 * 3 + p3) * t3
                out.append((a + b + c + d) * 0.5)
            }
        }
        out.append(p[p.count - 1])
        return out
    }

    /// Straight edges as closely spaced points, with each corner exact, so pen smoothing can't round them off.
    static func densify(_ verts: [CGPoint], closed: Bool, spacing: CGFloat = 2.5) -> [CGPoint] {
        guard let first = verts.first else { return [] }
        let path = closed ? verts + [first] : verts
        var out = [first]
        for (a, b) in zip(path, path.dropFirst()) {
            let steps = max(1, Int((a.distance(to: b) / spacing).rounded(.up)))
            for j in 1...steps { out.append(a + (b - a) * (CGFloat(j) / CGFloat(steps))) }
        }
        return out
    }

    // MARK: Tidying helpers

    static func snapAngle(_ a: CGFloat, step: CGFloat, tolerance degrees: CGFloat) -> CGFloat {
        let nearest = (a / step).rounded() * step
        return abs(a - nearest) < degrees * .pi / 180 ? nearest : a
    }

    /// Edges within 4 degrees of level or upright become exactly so.
    static func levelEdges(_ points: [CGPoint], closed: Bool) -> [CGPoint] {
        var p = points
        let n = p.count
        guard n > 1 else { return p }
        let tolerance = tan(4 * CGFloat.pi / 180)
        for i in 0..<(closed ? n : n - 1) {
            let j = (i + 1) % n
            let d = p[j] - p[i]
            if abs(d.y) <= tolerance * abs(d.x) {
                let y = (p[i].y + p[j].y) / 2
                p[i].y = y; p[j].y = y
            } else if abs(d.x) <= tolerance * abs(d.y) {
                let x = (p[i].x + p[j].x) / 2
                p[i].x = x; p[j].x = x
            }
        }
        return p
    }

    /// Four corners that are all within 18 degrees of square become a true rectangle (or square), level when nearly so.
    static func rectangle(from p: [CGPoint]) -> [CGPoint]? {
        guard p.count == 4 else { return nil }
        for i in 0..<4 where abs(turn(p[(i + 3) % 4], p[i], p[(i + 1) % 4]) - 90) > 18 { return nil }
        // Average edge direction, folded to a quarter turn.
        var cs: CGFloat = 0, sn: CGFloat = 0
        for i in 0..<4 {
            let d = p[(i + 1) % 4] - p[i]
            let a = atan2(d.y, d.x)
            cs += d.length * cos(4 * a); sn += d.length * sin(4 * a)
        }
        let theta = snapAngle(atan2(sn, cs) / 4, step: .pi / 2, tolerance: 6)
        let c = centroid(p)
        let local = p.map { rotate($0 - c, by: -theta) }
        let xs = local.map(\.x).sorted(), ys = local.map(\.y).sorted()
        var x0 = (xs[0] + xs[1]) / 2, x1 = (xs[2] + xs[3]) / 2
        var y0 = (ys[0] + ys[1]) / 2, y1 = (ys[2] + ys[3]) / 2
        let w = x1 - x0, h = y1 - y0
        if abs(w - h) < 0.08 * max(w, h) {
            let side = (w + h) / 2, mx = (x0 + x1) / 2, my = (y0 + y1) / 2
            x0 = mx - side / 2; x1 = mx + side / 2; y0 = my - side / 2; y1 = my + side / 2
        }
        return [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)].map { c + rotate($0, by: theta) }
    }

    /// Even sides and even angles become a regular polygon, turned to sit flat or point up when it nearly does.
    static func regularPolygon(from p: [CGPoint]) -> [CGPoint]? {
        let n = p.count
        guard n == 3 || n >= 5 else { return nil }
        let sides = (0..<n).map { p[$0].distance(to: p[($0 + 1) % n]) }
        let mean = sides.reduce(0, +) / CGFloat(n)
        let spread = sqrt(sides.reduce(CGFloat(0)) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(n)) / mean
        // Triangles are often meant to be isosceles or scalene, so only nearly perfect ones become equilateral.
        guard spread < (n == 3 ? 0.07 : 0.22) else { return nil }
        let expected = 360 / CGFloat(n)
        for i in 0..<n where abs(turn(p[(i + n - 1) % n], p[i], p[(i + 1) % n]) - expected) > (n == 3 ? 7 : 20) { return nil }
        let c = centroid(p)
        let radius = p.reduce(CGFloat(0)) { $0 + $1.distance(to: c) } / CGFloat(n)
        let step = 2 * CGFloat.pi / CGFloat(n)
        // Keep the drawn direction of travel so handles stay in order.
        let clockwise = (0..<n).reduce(CGFloat(0)) { $0 + cross(p[$1] - c, p[($1 + 1) % n] - c) } > 0
        var phase = atan2(p[0].y - c.y, p[0].x - c.x)
        for base in [-CGFloat.pi / 2, -CGFloat.pi / 2 + step / 2] {
            let k = ((phase - base) / step).rounded()
            if abs(phase - (base + k * step)) < 12 * .pi / 180 { phase = base + k * step; break }
        }
        return (0..<n).map { i in
            let a = phase + (clockwise ? 1 : -1) * step * CGFloat(i)
            return CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
        }
    }

    /// Drag one corner of a rectangle, keeping the opposite corner pinned and every angle square.
    static func resizeRectangle(_ p: [CGPoint], corner i: Int, to target: CGPoint) -> [CGPoint] {
        let edge = p[1] - p[0]
        let theta = atan2(edge.y, edge.x)
        let o = (i + 2) % 4
        let pinned = rotate(p[o], by: -theta), moved = rotate(target, by: -theta)
        var local = p.map { rotate($0, by: -theta) }
        // Edges 0-1 and 2-3 run along the rectangle's own x axis; i^1 is the neighbour sharing that edge.
        local[i] = moved
        local[o] = pinned
        local[i ^ 1] = CGPoint(x: pinned.x, y: moved.y)
        local[o ^ 1] = CGPoint(x: moved.x, y: pinned.y)
        return local.map { rotate($0, by: theta) }
    }

    /// Where `p` lands when the segment `from` is moved, scaled and turned onto `to`.
    static func similarity(_ p: CGPoint, from: (CGPoint, CGPoint), to: (CGPoint, CGPoint)) -> CGPoint {
        let u = from.0 - from.1, v = to.0 - to.1
        let ul = u.length
        guard ul > 1e-6 else { return p + (to.1 - from.1) }
        let scale = v.length / ul
        let angle = atan2(v.y, v.x) - atan2(u.y, u.x)
        return to.1 + rotate(p - from.1, by: angle) * scale
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { (self - p).length }
    var length: CGFloat { sqrt(x * x + y * y) }
    var normalized: CGPoint {
        let l = length
        return l > 1e-9 ? CGPoint(x: x / l, y: y / l) : .zero
    }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static prefix func - (a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: -a.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
}
