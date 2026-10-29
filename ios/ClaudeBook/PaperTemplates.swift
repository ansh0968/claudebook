import UIKit

/// The server and iPad consume the same page-unit primitives, including structured writing regions.
enum PaperTemplates {
    struct Primitive: Decodable {
        var kind: String
        var x: Double
        var y: Double
        var x2: Double?
        var y2: Double?
        var width: Double?
        var role: String
        var r: Double?
        var dash: [Double]?
    }
    struct Template: Decodable { var title: String; var primitives: [Primitive]; var regions: [String]? }
    struct Paper: Decodable { var title: String; var color: String; var dark: Bool }
    struct Data: Decodable {
        var papers: [String: Paper]
        var palettes: [String: [String: String]]
        var templates: [String: Template]
    }
    static let data: Data = {
        guard let url = Bundle.main.url(forResource: "paper-templates", withExtension: "json"),
              let bytes = try? Foundation.Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Data.self, from: bytes) else {
            preconditionFailure("The shared paper-templates.json resource must be bundled")
        }
        return value
    }()

    static func draw(_ background: PageBackground, paper: PaperColor, in ctx: CGContext) {
        guard let sheet = data.papers[paper.rawValue], let template = data.templates[background.rawValue] else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: PageGeometry.rect)
        ctx.setFillColor(UIColor(hex: sheet.color).cgColor)
        ctx.fill(PageGeometry.rect)
        let palette = data.palettes[sheet.dark ? "dark" : "light"] ?? [:]
        for p in template.primitives {
            let color = UIColor(hex: palette[p.role] ?? sheet.color).cgColor
            if p.kind == "dot" {
                let r = p.r ?? 1.4
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(p.width ?? 1)
                ctx.setLineDash(phase: 0, lengths: (p.dash ?? []).map { CGFloat($0) })
                ctx.move(to: CGPoint(x: p.x, y: p.y))
                ctx.addLine(to: CGPoint(x: p.x2 ?? p.x, y: p.y2 ?? p.y))
                ctx.strokePath()
            }
        }
    }
}

extension Page {
    func usesDarkInkPalette(appDark: Bool) -> Bool { paper?.isDark ?? appDark }
}

extension API {
    /// The multi-select page UI can pass any stable page-id selection here.
    func setBackground(pageIds: [String], background: PageBackground?, paper: PaperColor?) async throws {
        struct Body: Encodable { var pageIds: [String]; var background: PageBackground?; var paper: PaperColor? }
        _ = try await request("pages/background", method: "POST", json: Body(pageIds: pageIds, background: background, paper: paper))
    }
}
