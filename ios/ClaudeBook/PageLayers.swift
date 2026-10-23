import PDFKit
import UIKit

/// Paper: blank, lined, grid, dotted, or a PDF page. Views draw in page coordinates scaled to their bounds,
/// so they can be resized to the current zoom and redrawn crisp.
final class PaperView: UIView {
    var background: PageBackground = .blank { didSet { setNeedsDisplay() } }
    var pdfPage: PDFPage? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        contentMode = .scaleToFill
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = bounds.width / PageGeometry.width
        ctx.scaleBy(x: scale, y: scale)
        Self.drawPaper(background, pdf: pdfPage, pixelScale: scale * contentScaleFactor, in: ctx)
    }

    static func drawPaper(_ background: PageBackground, pdf: PDFPage? = nil, pixelScale: CGFloat = 1, in ctx: CGContext) {
        let w = PageGeometry.width, h = PageGeometry.height
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(PageGeometry.rect)
        if let pdf {
            // Aspect-fit and centered, same as the server's rasterizer.
            let box = pdf.bounds(for: .mediaBox)
            let rotated = abs(pdf.rotation) % 180 == 90
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let fit = min(w / size.width, h / size.height)
            let target = CGRect(x: (w - size.width * fit) / 2, y: (h - size.height * fit) / 2, width: size.width * fit, height: size.height * fit)
            let px = CGSize(width: min(4096, target.width * pixelScale), height: min(4096 * target.height / target.width, target.height * pixelScale))
            UIGraphicsPushContext(ctx)
            pdf.thumbnail(of: px, for: .mediaBox).draw(in: target)
            UIGraphicsPopContext()
            return
        }
        switch background {
        case .blank:
            break
        case .lined:
            ctx.setStrokeColor(UIColor(hex: "#C9D7E8").cgColor)
            ctx.setLineWidth(1.5)
            var y: CGFloat = 120
            while y < h - 40 { ctx.move(to: CGPoint(x: 40, y: y)); ctx.addLine(to: CGPoint(x: w - 40, y: y)); y += 40 }
            ctx.strokePath()
        case .grid:
            ctx.setStrokeColor(UIColor(hex: "#E3EAF2").cgColor)
            ctx.setLineWidth(1)
            var x: CGFloat = 25
            while x < w { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)); x += 25 }
            var y: CGFloat = 25
            while y < h { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); y += 25 }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(UIColor(hex: "#C9D2DC").cgColor)
            var x: CGFloat = 25
            while x < w {
                var y: CGFloat = 25
                while y < h { ctx.fillEllipse(in: CGRect(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8)); y += 25 }
                x += 25
            }
        }
    }
}

/// Claude's ink, drawn natively so it stays crisp at any zoom. Never takes touches.
final class ClaudeLayerView: UIView {
    var items: [ClaudeItem] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .scaleToFill
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = bounds.width / PageGeometry.width
        ctx.scaleBy(x: scale, y: scale)
        for item in items { ClaudeRenderer.draw(item, in: ctx) }
    }
}

/// Downloads each PDF once and keeps it on disk.
enum PDFCache {
    private static var dir: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "pdfs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static var open: [String: PDFDocument] = [:]

    @MainActor
    static func page(_ ref: PDFRef) async -> PDFPage? {
        if let doc = open[ref.file] { return doc.page(at: ref.page - 1) }
        let url = dir.appending(path: "\(ref.file).pdf")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? await API.current?.pdf(file: ref.file) else { return nil }
            try? data.write(to: url, options: .atomic)
        }
        guard let doc = PDFDocument(url: url) else { return nil }
        open[ref.file] = doc
        return doc.page(at: ref.page - 1)
    }
}

enum ClaudeRenderer {
    static let defaultColor = "#D97757"

    static func draw(_ item: ClaudeItem, in ctx: CGContext) {
        let color = UIColor(hex: item.color ?? defaultColor)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(item.width ?? 3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func pt(_ a: [Double]?) -> CGPoint? {
            guard let a, a.count >= 2 else { return nil }
            return CGPoint(x: a[0], y: a[1])
        }
        func strokeAndFill(_ path: CGPath) {
            if let fill = item.fill, fill != "none" {
                ctx.addPath(path)
                ctx.setFillColor(UIColor(hex: fill).cgColor)
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.strokePath()
        }

        switch item.type {
        case "path":
            let pts = (item.points ?? []).compactMap { pt($0) }
            guard pts.count >= 2 else { return }
            ctx.addPath(smoothPath(pts, closed: item.closed ?? false))
            ctx.strokePath()
        case "line":
            guard let a = pt(item.from), let b = pt(item.to) else { return }
            if item.dashed == true { ctx.setLineDash(phase: 0, lengths: [10, 8]) }
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        case "arrow":
            guard let a = pt(item.from), let b = pt(item.to) else { return }
            let angle = atan2(b.y - a.y, b.x - a.x), head = 10 + (item.width ?? 3) * 2
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.move(to: CGPoint(x: b.x - head * cos(angle - 0.45), y: b.y - head * sin(angle - 0.45)))
            ctx.addLine(to: b)
            ctx.addLine(to: CGPoint(x: b.x - head * cos(angle + 0.45), y: b.y - head * sin(angle + 0.45)))
            ctx.strokePath()
        case "ellipse":
            guard let c = pt(item.center), let rx = item.rx else { return }
            let ry = item.ry ?? rx
            strokeAndFill(CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2), transform: nil))
        case "rect":
            guard let r = rect(item) else { return }
            strokeAndFill(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
        case "highlight":
            guard let r = rect(item) else { return }
            ctx.setFillColor(UIColor(hex: item.color ?? "#FFE066").withAlphaComponent(0.45).cgColor)
            ctx.fill(r)
        case "text":
            guard let text = item.text, let x = item.x, let y = item.y else { return }
            let size = item.size ?? 32
            let font = UIFont(name: "Noteworthy-Light", size: size * 0.8) ?? .systemFont(ofSize: size * 0.8)
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = size
            para.maximumLineHeight = size
            UIGraphicsPushContext(ctx)
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
            UIGraphicsPopContext()
        case "svg":
            guard let d = item.d else { return }
            strokeAndFill(SVGPath.parse(d))
        case "math":
            // The server typesets LaTeX into one flattened path in page coordinates.
            guard let d = item.d else { return }
            ctx.addPath(SVGPath.parse(d))
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        default:
            break
        }
    }

    private static func rect(_ item: ClaudeItem) -> CGRect? {
        guard let x = item.x, let y = item.y, let w = item.w, let h = item.h else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Catmull-Rom spline through the points, same as the server.
    static func smoothPath(_ points: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 3 else {
            path.addLines(between: points)
            return path
        }
        let pts = closed ? [points.last!] + points + [points[0], points[1]] : [points[0]] + points + [points.last!]
        path.move(to: pts[1])
        for i in 1..<(pts.count - 2) {
            let p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }
}

/// Minimal SVG path-data parser: M L H V C S Q T Z (absolute and relative). Arcs are approximated with a line.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var current = ""
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else if ch == "-" && !current.isEmpty && !current.hasSuffix("e") && !current.hasSuffix("E") {
                tokens.append(current); current = "-"
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        var i = 0
        var cmd: Character = "M"
        var pos = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        func num() -> CGFloat? {
            guard i < tokens.count, let v = Double(tokens[i]) else { return nil }
            i += 1
            return CGFloat(v)
        }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter, tokens[i].count == 1 { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            func p() -> CGPoint? {
                guard let x = num(), let y = num() else { return nil }
                return rel ? CGPoint(x: pos.x + x, y: pos.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd.uppercased() {
            case "M":
                guard let q = p() else { return path }
                path.move(to: q); pos = q; start = q
                cmd = rel ? "l" : "L"
                lastControl = nil
            case "L":
                guard let q = p() else { return path }
                path.addLine(to: q); pos = q; lastControl = nil
            case "H":
                guard let x = num() else { return path }
                pos = CGPoint(x: rel ? pos.x + x : x, y: pos.y); path.addLine(to: pos); lastControl = nil
            case "V":
                guard let y = num() else { return path }
                pos = CGPoint(x: pos.x, y: rel ? pos.y + y : y); path.addLine(to: pos); lastControl = nil
            case "C":
                guard let c1 = p(), let c2 = p(), let q = p() else { return path }
                path.addCurve(to: q, control1: c1, control2: c2); pos = q; lastControl = c2
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * pos.x - $0.x, y: 2 * pos.y - $0.y) } ?? pos
                guard let c2 = p(), let q = p() else { return path }
                path.addCurve(to: q, control1: c1, control2: c2); pos = q; lastControl = c2
            case "Q":
                guard let c = p(), let q = p() else { return path }
                path.addQuadCurve(to: q, control: c); pos = q; lastControl = c
            case "T":
                let c = lastControl.map { CGPoint(x: 2 * pos.x - $0.x, y: 2 * pos.y - $0.y) } ?? pos
                guard let q = p() else { return path }
                path.addQuadCurve(to: q, control: c); pos = q; lastControl = c
            case "A":
                guard num() != nil, num() != nil, num() != nil, num() != nil, num() != nil, let q = p() else { return path }
                path.addLine(to: q); pos = q; lastControl = nil
            case "Z":
                path.closeSubpath(); pos = start; lastControl = nil
                if i < tokens.count, Double(tokens[i]) != nil { return path }
            default:
                return path
            }
        }
        return path
    }
}

extension UIColor {
    /// "#RGB", "#RRGGBB", "#RRGGBBAA" or a few common names. Falls back to Claude orange.
    convenience init(hex: String) {
        let names = ["red": "#E5484D", "green": "#30A46C", "blue": "#3B82F6", "black": "#1F1D1A", "orange": "#D97757", "yellow": "#FFE066", "purple": "#8E4EC6"]
        var s = (names[hex.lowercased()] ?? hex).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        guard (s.count == 6 || s.count == 8), Scanner(string: s).scanHexInt64(&v) else {
            self.init(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
            return
        }
        if s.count == 8 {
            self.init(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255, blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        } else {
            self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }
}
