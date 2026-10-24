import UIKit

/// Everything that decides how a page's paper looks. Tiles draw on background threads, so views hold
/// this as one value swapped under a lock rather than several separately mutable properties.
struct PaperStyle {
    var background: PageBackground = .blank
    var pdf: CGPDFPage?
    var dark = false
    var invertPDF = true
}

/// A CATiledLayer that shows new tiles at once instead of fading them in.
final class InstantTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// A page-sized view whose bounds are always the page (1000x1414 units); the canvas scales it with a
/// transform. Tiled, so zooming in redraws just the visible tiles sharper instead of one giant bitmap.
class TiledPageView: UIView {
    override class var layerClass: AnyClass { InstantTiledLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tiled = layer as! CATiledLayer
        // 2 zoomed-out levels and 5 magnified ones covers fit-to-width up to 5x zoom on a 2x screen.
        tiled.levelsOfDetail = 7
        tiled.levelsOfDetailBias = 5
        tiled.tileSize = CGSize(width: 512, height: 512)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Paper: blank, lined, grid, dotted, or a PDF page.
final class PaperView: TiledPageView {
    private let lock = NSLock()
    private var _style = PaperStyle()

    var style: PaperStyle {
        get { lock.lock(); defer { lock.unlock() }; return _style }
        set {
            lock.lock(); _style = newValue; lock.unlock()
            layer.shadowOpacity = newValue.dark ? 0 : 0.16
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 5
        layer.shadowPath = UIBezierPath(rect: PageGeometry.rect).cgPath
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        Self.drawPaper(style, in: ctx)
    }

    static let lightPaper = UIColor(hex: "#FFFEFA")
    static let darkPaper = UIColor(hex: "#1D2527")

    /// Draws the page in page units. Snapshots for Claude always pass a light style.
    static func drawPaper(_ style: PaperStyle, in ctx: CGContext) {
        let w = PageGeometry.width, h = PageGeometry.height
        ctx.setFillColor((style.dark ? darkPaper : lightPaper).cgColor)
        ctx.fill(PageGeometry.rect)
        if let pdf = style.pdf {
            drawPDF(pdf, in: ctx, invert: style.dark && style.invertPDF)
            return
        }
        let dark = style.dark
        switch style.background {
        case .blank:
            break
        case .lined:
            ctx.setStrokeColor(UIColor(hex: dark ? "#324347" : "#D9DDD5").cgColor)
            ctx.setLineWidth(1.5)
            var y: CGFloat = 120
            while y < h - 40 { ctx.move(to: CGPoint(x: 40, y: y)); ctx.addLine(to: CGPoint(x: w - 40, y: y)); y += 40 }
            ctx.strokePath()
        case .grid:
            ctx.setStrokeColor(UIColor(hex: dark ? "#2D3C3E" : "#E5E7DE").cgColor)
            ctx.setLineWidth(1)
            var x: CGFloat = 25
            while x < w { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)); x += 25 }
            var y: CGFloat = 25
            while y < h { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); y += 25 }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(UIColor(hex: dark ? "#455355" : "#D3D8CF").cgColor)
            var x: CGFloat = 25
            while x < w {
                var y: CGFloat = 25
                while y < h { ctx.fillEllipse(in: CGRect(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8)); y += 25 }
                x += 25
            }
        }
    }

    /// Where a PDF page lands: aspect-fit and centered, same as the server's rasterizer.
    static func pdfRect(_ page: CGPDFPage) -> CGRect {
        let box = page.getBoxRect(.mediaBox)
        let quarter = (Int(page.rotationAngle) % 360 + 360) % 360
        let size = quarter == 90 || quarter == 270 ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return PageGeometry.rect }
        let fit = min(PageGeometry.width / size.width, PageGeometry.height / size.height)
        return CGRect(x: (PageGeometry.width - size.width * fit) / 2, y: (PageGeometry.height - size.height * fit) / 2,
                      width: size.width * fit, height: size.height * fit)
    }

    /// Vector PDF drawing, so it stays sharp at every zoom level. Dark mode inverts it (black text on
    /// white becomes light text on dark paper).
    static func drawPDF(_ page: CGPDFPage, in ctx: CGContext, invert: Bool) {
        let box = page.getBoxRect(.mediaBox)
        let target = pdfRect(page)
        let quarter = (Int(page.rotationAngle) % 360 + 360) % 360
        let displayWidth = quarter == 90 || quarter == 270 ? box.height : box.width
        guard displayWidth > 0 else { return }
        let fit = target.width / displayWidth

        ctx.saveGState()
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(target)
        ctx.saveGState()
        ctx.clip(to: target)
        // Flip into PDF space (y up) with the origin at the target's bottom left, then apply /Rotate.
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: fit, y: -fit)
        switch quarter {
        case 90: ctx.translateBy(x: 0, y: box.width); ctx.rotate(by: -.pi / 2)
        case 180: ctx.translateBy(x: box.width, y: box.height); ctx.rotate(by: .pi)
        case 270: ctx.translateBy(x: box.height, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        if invert {
            ctx.setBlendMode(.difference)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(target)
            // Lift pure black to the dark paper color so the PDF blends into the page.
            ctx.setBlendMode(.lighten)
            ctx.setFillColor(darkPaper.cgColor)
            ctx.fill(target)
        }
        ctx.restoreGState()
    }
}

/// Claude's ink, drawn natively so it stays crisp at any zoom. Never takes touches.
final class ClaudeLayerView: TiledPageView {
    private let lock = NSLock()
    private var _items: [ClaudeItem] = []
    private var _dark = false
    private var _doubts: [Doubt] = []

    func update(items: [ClaudeItem], dark: Bool, doubts: [Doubt] = []) {
        lock.lock()
        let same = items == _items && dark == _dark && doubts == _doubts
        _items = items
        _dark = dark
        _doubts = doubts
        lock.unlock()
        if !same { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        lock.lock()
        let items = _items, dark = _dark, doubts = _doubts
        lock.unlock()
        for item in items { ClaudeRenderer.draw(item, dark: dark, in: ctx) }
        for doubt in doubts where doubt.isOpen { ClaudeRenderer.drawDoubt(doubt, dark: dark, in: ctx) }
    }
}

/// Downloads each PDF once and keeps it on disk.
@MainActor
enum PDFCache {
    private static let dir: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "pdfs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static var open: [String: CGPDFDocument] = [:]

    /// The page if its PDF is already open, so freshly shown pages don't flash blank.
    static func cached(_ ref: PDFRef) -> CGPDFPage? {
        open[ref.file]?.page(at: ref.page)
    }

    static func page(_ ref: PDFRef) async -> CGPDFPage? {
        if let page = cached(ref) { return page }
        let url = dir.appending(path: "\(ref.file).pdf")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? await API.current?.pdf(file: ref.file) else { return nil }
            try? data.write(to: url, options: .atomic)
        }
        guard let doc = CGPDFDocument(url as CFURL) else { return nil }
        open[ref.file] = doc
        return doc.page(at: ref.page)
    }
}

enum ClaudeRenderer {
    static let defaultColor = "#D97757"
    /// Parsed outlines for server-rendered items, which tiles would otherwise re-parse for every tile.
    private static let paths = NSCache<NSString, CGPath>()

    private static func outline(_ item: ClaudeItem, _ d: String) -> CGPath {
        // Moves and hint reveals can replace an outline without changing its character count.
        let key = d as NSString
        if let path = paths.object(forKey: key) { return path }
        let path = SVGPath.parse(d)
        paths.setObject(path, forKey: key)
        return path
    }

    /// In dark mode, very dark colors (black ink, navy) flip to light versions of the same hue.
    static func adapt(_ color: UIColor, dark: Bool) -> UIColor {
        guard dark else { return color }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a), 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.3 else { return color }
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
        return UIColor(hue: hue, saturation: sat * 0.6, brightness: max(0.85, 1 - bri * 0.3), alpha: a)
    }

    static func draw(_ item: ClaudeItem, dark: Bool = false, in ctx: CGContext) {
        let color = adapt(UIColor(hex: item.color ?? defaultColor), dark: dark)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(item.width ?? 3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if let parts = item.parts {
            for part in parts {
                ctx.saveGState()
                if let clip = part.clip {
                    ctx.addPath(outline(item, clip))
                    ctx.clip()
                }
                ctx.setAlpha(part.opacity ?? 1)
                ctx.setLineWidth(part.width ?? 3)
                ctx.setLineDash(phase: 0, lengths: (part.dash ?? []).map { CGFloat($0) })
                let path = outline(item, part.d)
                if let fill = part.fill, fill != "none" {
                    ctx.setFillColor(adapt(UIColor(hex: fill), dark: dark).cgColor)
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                if let stroke = part.stroke, stroke != "none" {
                    ctx.setStrokeColor(adapt(UIColor(hex: stroke), dark: dark).cgColor)
                    ctx.addPath(path)
                    ctx.strokePath()
                }
                ctx.restoreGState()
            }
            return
        }

        func pt(_ a: [Double]?) -> CGPoint? {
            guard let a, a.count >= 2 else { return nil }
            return CGPoint(x: a[0], y: a[1])
        }
        func strokeAndFill(_ path: CGPath) {
            let filled = item.fill.map { $0 != "none" } ?? false
            if filled, let fill = item.fill {
                ctx.addPath(path)
                ctx.setFillColor(adapt(UIColor(hex: fill), dark: dark).cgColor)
                ctx.fillPath()
            }
            // A fill with no color is a fill-only shape, same as the server.
            guard !filled || item.color != nil else { return }
            ctx.addPath(path)
            ctx.strokePath()
        }
        func dash() {
            if item.dashed == true { ctx.setLineDash(phase: 0, lengths: [10, 8]) }
        }
        /// Heads are never dashed; filled ones are stroked too so their tips match the line's round cap.
        func heads() {
            guard let d = item.headD, !d.isEmpty else { return }
            ctx.setLineDash(phase: 0, lengths: [])
            let path = outline(item, d)
            if item.headFilled == true {
                ctx.addPath(path)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.strokePath()
        }

        switch item.type {
        case "path":
            let pts = (item.points ?? []).compactMap { pt($0) }
            guard pts.count >= 2 else { return }
            if item.smooth == false {
                ctx.move(to: pts[0])
                for point in pts.dropFirst() { ctx.addLine(to: point) }
                if item.closed == true { ctx.closePath() }
            } else {
                ctx.addPath(smoothPath(pts, closed: item.closed ?? false))
            }
            dash()
            ctx.strokePath()
            heads()
        case "line":
            guard let a = pt(item.from), let b = pt(item.to) else { return }
            if item.dashed == true { ctx.setLineDash(phase: 0, lengths: [10, 8]) }
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        case "arrow":
            guard let a = pt(item.from), let b = pt(item.to) else { return }
            // Newer arrows carry their heads (none, start, end, both, filled) as head_d.
            if item.headD != nil || item.head != nil {
                dash()
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                heads()
                return
            }
            let angle = atan2(b.y - a.y, b.x - a.x), head = 10 + (item.width ?? 3) * 2
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.move(to: CGPoint(x: b.x - head * cos(angle - 0.45), y: b.y - head * sin(angle - 0.45)))
            ctx.addLine(to: b)
            ctx.addLine(to: CGPoint(x: b.x - head * cos(angle + 0.45), y: b.y - head * sin(angle + 0.45)))
            ctx.strokePath()
        case "curved_arrow":
            guard let a = pt(item.from), let b = pt(item.to) else { return }
            let dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            let bend = CGFloat(item.bend ?? 40)
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let control = CGPoint(x: (a.x + b.x) / 2 + normal.x * bend,
                                  y: (a.y + b.y) / 2 + normal.y * bend)
            ctx.move(to: a)
            ctx.addQuadCurve(to: b, control: control)
            let angle = atan2(b.y - control.y, b.x - control.x)
            let head = CGFloat(10 + (item.width ?? 3) * 2)
            let barbs = [-0.45, 0.45].map { offset in
                CGPoint(x: b.x - head * cos(angle + offset), y: b.y - head * sin(angle + offset))
            }
            let selected = item.halfHead == true ? [barbs[bend >= 0 ? 1 : 0]] : barbs
            for barb in selected { ctx.move(to: barb); ctx.addLine(to: b) }
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
            ctx.setFillColor(UIColor(hex: item.color ?? "#FFE066").withAlphaComponent(dark ? 0.32 : 0.45).cgColor)
            ctx.fill(r)
        case "text":
            // The server ships the handwriting as outlines so both sides draw identical shapes.
            if let d = item.d, !d.isEmpty {
                ctx.addPath(outline(item, d))
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
                return
            }
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
            dash()
            strokeAndFill(outline(item, d))
            heads()
        case "math", "molecule":
            // The server typesets LaTeX into one flattened path in page coordinates.
            guard let d = item.d else { return }
            ctx.addPath(outline(item, d))
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        case "hint":
            if item.revealed != true, let chip = rect(item) {
                let path = CGPath(roundedRect: chip, cornerWidth: 8, cornerHeight: 8, transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(color.withAlphaComponent(dark ? 0.16 : 0.10).cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
            }
            if let d = item.d {
                ctx.addPath(outline(item, d))
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            } else if let x = item.x, let y = item.y {
                let text = item.revealed == true ? (item.text ?? "") : (item.label ?? "Hint")
                let font = UIFont(name: "Noteworthy-Light", size: (item.size ?? 28) * 0.8) ?? .systemFont(ofSize: (item.size ?? 28) * 0.8)
                UIGraphicsPushContext(ctx)
                (text as NSString).draw(at: CGPoint(x: x + (item.revealed == true ? 0 : 12), y: y + (item.revealed == true ? 0 : 3)), withAttributes: [.font: font, .foregroundColor: color])
                UIGraphicsPopContext()
            }
        default:
            break
        }
    }

    static func drawDoubt(_ doubt: Doubt, dark: Bool, in ctx: CGContext) {
        let r = doubt.region
        let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
        guard rect.width > 0, rect.height > 0 else { return }
        let coral = UIColor(hex: "#D97757")
        ctx.saveGState()
        ctx.setStrokeColor(coral.withAlphaComponent(dark ? 0.85 : 0.62).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 7])
        ctx.stroke(rect.insetBy(dx: -6, dy: -6))
        ctx.setLineDash(phase: 0, lengths: [])
        let badge = CGRect(x: max(0, rect.minX - 18), y: max(0, rect.minY - 18), width: 28, height: 28)
        ctx.setFillColor(coral.cgColor)
        ctx.fillEllipse(in: badge)
        let mark = "?" as NSString
        UIGraphicsPushContext(ctx)
        mark.draw(in: badge.insetBy(dx: 7, dy: 2), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.white])
        UIGraphicsPopContext()
        ctx.restoreGState()
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
