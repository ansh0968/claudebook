import CoreGraphics
import XCTest
@testable import ClaudeBook

/// Hand-drawn strokes are faked with smooth wobble, a slight overshoot and the pencil resting at the end.
final class ShapeRecognizerTests: XCTestCase {
    private func wobbly(_ points: [CGPoint], amount: CGFloat = 1.2, seed: UInt64 = 1) -> [CGPoint] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func noise() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(Double(state >> 11) / Double(1 << 53)) * 2 - 1
        }
        var ox: CGFloat = 0, oy: CGFloat = 0
        let out = points.map { p -> CGPoint in
            ox = 0.8 * ox + amount * noise()
            oy = 0.8 * oy + amount * noise()
            return CGPoint(x: p.x + ox, y: p.y + oy)
        }
        return out + Array(repeating: out[out.count - 1], count: 20)
    }

    private func polyline(_ v: [CGPoint], closed: Bool, per: Int = 30) -> [CGPoint] {
        let path = closed ? v + [v[0]] : v
        var out: [CGPoint] = []
        for (a, b) in zip(path, path.dropFirst()) {
            for j in 0..<per { out.append(a + (b - a) * (CGFloat(j) / CGFloat(per))) }
        }
        return out + [path[path.count - 1]]
    }

    private func oval(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, turn: CGFloat = 0, overshoot: CGFloat = 0.05) -> [CGPoint] {
        (0..<Int(100 * (1 + overshoot))).map { i -> CGPoint in
            let t: CGFloat = 0.3 + 2 * CGFloat.pi * CGFloat(i) / 100
            let v = CGPoint(x: rx * cos(t), y: ry * sin(t))
            return c + Geo.rotate(v, by: turn)
        }
    }

    private func arc(_ c: CGPoint, _ r: CGFloat) -> [CGPoint] {
        (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40 * .pi
            return CGPoint(x: c.x + r * cos(t), y: c.y - r * sin(t))
        }
    }

    private func headed(_ shaft: [CGPoint], length: CGFloat = 40, half: Bool = false) -> [CGPoint] {
        let tip = shaft[shaft.count - 1], dir = (tip - shaft[shaft.count - 4]).normalized
        let spread = 28 * CGFloat.pi / 180
        let b1 = tip + Geo.rotate(dir * -length, by: spread), b2 = tip + Geo.rotate(dir * -length, by: -spread)
        return shaft + polyline(half ? [tip, b1] : [tip, b1, tip, b2], closed: false, per: 14).dropFirst()
    }

    private func recognize(_ points: [CGPoint], seeds: ClosedRange<UInt64> = 1...6) -> [SnapShape?] {
        seeds.map { ShapeRecognizer.recognize(wobbly(points, seed: $0)) }
    }

    // MARK: Recognition

    func testCircleBecomesARoundCircle() throws {
        for shape in recognize(oval(CGPoint(x: 300, y: 300), 120, 120)) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.kind, .ellipse)
            XCTAssertEqual(s.fit, .circle)
            XCTAssertEqual(s.radii.width, s.radii.height)
            XCTAssertEqual(s.radii.width, 120, accuracy: 8)
            XCTAssertEqual(s.points[0].x, 300, accuracy: 5)
            XCTAssertEqual(s.points[0].y, 300, accuracy: 5)
            XCTAssertEqual(s.name, "Circle")
        }
    }

    func testEllipseKeepsItsTilt() throws {
        for shape in recognize(oval(CGPoint(x: 300, y: 300), 180, 90, turn: 0.3)) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.kind, .ellipse)
            XCTAssertEqual(s.fit, .free)
            XCTAssertEqual(max(s.radii.width, s.radii.height), 180, accuracy: 14)
            XCTAssertEqual(min(s.radii.width, s.radii.height), 90, accuracy: 10)
        }
    }

    func testRectangleSquaresUpAndLevels() throws {
        let drawn = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 108), CGPoint(x: 396, y: 300), CGPoint(x: 98, y: 292)]
        for shape in recognize(polyline(drawn, closed: true)) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.kind, .polygon)
            XCTAssertEqual(s.fit, .rectangle)
            XCTAssertEqual(s.points.count, 4)
            for i in 0..<4 {
                XCTAssertEqual(Geo.turn(s.points[(i + 3) % 4], s.points[i], s.points[(i + 1) % 4]), 90, accuracy: 0.01)
            }
            // About 1.5 degrees off level when drawn, so it straightens.
            XCTAssertEqual(s.points[0].y, s.points[1].y, accuracy: 0.01)
            XCTAssertEqual(s.name, "Rectangle")
        }
    }

    func testNearSquareBecomesASquare() throws {
        let drawn = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 102), CGPoint(x: 304, y: 296), CGPoint(x: 101, y: 300)]
        let s = try XCTUnwrap(recognize(polyline(drawn, closed: true), seeds: 1...1)[0])
        XCTAssertEqual(s.name, "Square")
    }

    func testTriangleAndRegularPolygons() throws {
        for shape in recognize(polyline([CGPoint(x: 100, y: 300), CGPoint(x: 250, y: 80), CGPoint(x: 400, y: 300)], closed: true)) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.kind, .polygon)
            XCTAssertEqual(s.points.count, 3)
            // The base was level.
            XCTAssertEqual(s.points.map(\.y).filter { abs($0 - 300) < 6 }.count, 2)
        }
        let hexagon = (0..<6).map { k -> CGPoint in
            let a = CGFloat(k) * .pi / 3 + 0.05
            return CGPoint(x: 300 + 100 * cos(a), y: 300 + 100 * sin(a))
        }
        var regular = 0
        for shape in recognize(polyline(hexagon, closed: true)) {
            let s = try XCTUnwrap(shape)
            guard s.kind == .polygon, s.points.count == 6 else { continue }
            regular += s.fit == .regular ? 1 : 0
            XCTAssertEqual(s.name, "Hexagon")
        }
        XCTAssertGreaterThanOrEqual(regular, 5, "A benzene ring should come out as a regular hexagon")
    }

    func testLinesLevelAndCornersStaySharp() throws {
        for shape in recognize(polyline([CGPoint(x: 100, y: 200), CGPoint(x: 500, y: 214)], closed: false)) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.kind, .line)
            XCTAssertEqual(s.points[0].y, s.points[1].y, accuracy: 0.01, "2 degrees off level snaps level")
        }
        for shape in recognize(polyline([CGPoint(x: 100, y: 100), CGPoint(x: 101, y: 400), CGPoint(x: 500, y: 400)], closed: false)) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.kind, .polyline)
            XCTAssertEqual(s.points.count, 3)
        }
        let spring = (0...6).map { k -> CGPoint in CGPoint(x: 100 + CGFloat(k) * 30, y: k % 2 == 0 ? 200 : 150) }
        let springs = recognize(polyline(spring, closed: false, per: 12)).compactMap { $0 }
        XCTAssertGreaterThanOrEqual(springs.filter { $0.kind == .polyline }.count, 4)
    }

    func testArcsAndCurves() throws {
        for shape in recognize(arc(CGPoint(x: 300, y: 300), 150)) {
            XCTAssertEqual(try XCTUnwrap(shape).kind, .arc)
        }
        let parabola = stride(from: 150, through: 450, by: 5).map { x -> CGPoint in
            let d = CGFloat(x) - 300
            return CGPoint(x: CGFloat(x), y: 400 - d * d / 150)
        }
        for shape in recognize(parabola) {
            XCTAssertEqual(try XCTUnwrap(shape).kind, .curve)
        }
    }

    func testArrowsKeepTheirCurveAndHeads() throws {
        for shape in recognize(headed(polyline([CGPoint(x: 100, y: 300), CGPoint(x: 500, y: 200)], closed: false))) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.kind, .line)
            XCTAssertEqual(s.heads, .end)
            XCTAssertEqual(s.halfHead, 0)
            XCTAssertEqual(s.points[1].x, 500, accuracy: 8, "The shaft ends at the tip, not at a barb")
            XCTAssertEqual(s.paths(width: 3).count, 2)
        }
        for shape in recognize(headed(arc(CGPoint(x: 300, y: 300), 150), length: 30)) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.kind, .arc)
            XCTAssertEqual(s.heads, .end)
            XCTAssertEqual(s.name, "Curved arrow")
        }
        for shape in recognize(headed(arc(CGPoint(x: 300, y: 300), 80), length: 18, half: true)) {
            let s = try XCTUnwrap(shape)
            XCTAssertEqual(s.heads, .end)
            XCTAssertNotEqual(s.halfHead, 0)
            XCTAssertEqual(s.name, "Fishhook arrow")
        }
    }

    func testWritingAndDotsDoNotSnap() {
        let scribble = (0..<80).map { i -> CGPoint in
            let t = CGFloat(i)
            let y: CGFloat = 200 + 40 * sin(t * 0.9) + 20 * cos(t * 0.37)
            return CGPoint(x: 100 + t * 5, y: y)
        }
        XCTAssertTrue(recognize(scribble).allSatisfy { $0 == nil })
        XCTAssertNil(ShapeRecognizer.recognize([CGPoint(x: 10, y: 10), CGPoint(x: 13, y: 12), CGPoint(x: 12, y: 15)]))
        XCTAssertNil(ShapeRecognizer.recognize([CGPoint(x: 10, y: 10)]))
    }

    // MARK: Editing

    func testCircleRadiusHandleKeepsItRound() throws {
        let circle = SnapShape(kind: .ellipse, points: [CGPoint(x: 100, y: 100)], radii: CGSize(width: 50, height: 50), fit: .circle)
        let grown = circle.moving(.radius, to: CGPoint(x: 100, y: 180))
        XCTAssertEqual(grown.radii, CGSize(width: 80, height: 80))
        let moved = circle.moving(.move, to: CGPoint(x: 140, y: 90))
        XCTAssertEqual(moved.points[0], CGPoint(x: 140, y: 90))
        XCTAssertEqual(moved.radii, circle.radii)
    }

    func testRectangleCornerDragKeepsRightAngles() {
        let rect = SnapShape(kind: .polygon, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)], fit: .rectangle)
        let dragged = rect.moving(.vertex(2), to: CGPoint(x: 160, y: 90))
        XCTAssertEqual(dragged.points, [CGPoint(x: 0, y: 0), CGPoint(x: 160, y: 0), CGPoint(x: 160, y: 90), CGPoint(x: 0, y: 90)])
    }

    func testBendingALineMakesAnArcThroughTheHandle() throws {
        let line = SnapShape(kind: .line, points: [CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100)], heads: .end)
        let bent = line.moving(.bend, to: CGPoint(x: 100, y: 40))
        XCTAssertEqual(bent.kind, .arc)
        XCTAssertEqual(bent.heads, .end)
        let outline = bent.outline()
        let closest = outline.map { $0.distance(to: CGPoint(x: 100, y: 40)) }.min() ?? .infinity
        XCTAssertLessThan(closest, 1.5)
        XCTAssertEqual(outline.first!.x, 0, accuracy: 0.01)
        XCTAssertEqual(outline.last!.x, 200, accuracy: 0.01)
        // The arc's handles keep the same three slots, so a drag in progress carries on.
        XCTAssertEqual(bent.handles.count, line.handles.count)
    }

    func testMovingAnArrowEndCarriesTheBend() {
        let arrow = SnapShape(kind: .arc, points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: -30), CGPoint(x: 100, y: 0)], heads: .end)
        let longer = arrow.moving(.vertex(2), to: CGPoint(x: 200, y: 0))
        XCTAssertEqual(longer.points[2], CGPoint(x: 200, y: 0))
        XCTAssertEqual(longer.points[1].x, 100, accuracy: 0.01)
        XCTAssertEqual(longer.points[1].y, -60, accuracy: 0.01)
    }

    func testOutlinesCloseAndCornersAreExact() {
        let triangle = SnapShape(kind: .polygon, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 80)])
        let outline = triangle.outline()
        XCTAssertEqual(outline.first, outline.last)
        for corner in triangle.points { XCTAssertTrue(outline.contains(corner)) }
    }
}
