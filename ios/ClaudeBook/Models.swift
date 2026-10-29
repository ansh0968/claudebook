import Foundation
import CoreGraphics

/// Every page shares one logical coordinate space with the server, so Claude's coordinates map 1:1.
enum PageGeometry {
    static let width: CGFloat = 1000
    static let height: CGFloat = 1414
    static let size = CGSize(width: width, height: height)
    static let rect = CGRect(origin: .zero, size: size)
}

enum PageBackground: String, Codable, CaseIterable {
    case blank, lined, grid, dotted, lines_full, lined_narrow, lined_wide, lined_margin, grid_small, grid_large, graph, dotted_large, isometric, hex, cornell, music, handwriting, two_column
}

enum PaperColor: String, Codable, CaseIterable {
    case `default`, white, black, cream, yellow, slate
    var isDark: Bool { self == .black || self == .slate }
}

struct TextBox: Codable, Hashable {
    var text: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var alts: [String]? = nil
    var confidence: Double? = nil
}

struct PageRegion: Codable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct Doubt: Codable, Identifiable, Hashable {
    var id: String
    var pageId: String
    var region: PageRegion
    var createdAt: String
    var resolvedAt: String?
    var isOpen: Bool { resolvedAt == nil }
}

/// One thing Claude drew. Mirrors the server's item union with optional fields.
struct ClaudePart: Codable, Hashable {
    var d: String
    var stroke: String?
    var fill: String?
    var width: Double?
    var dash: [Double]?
    var opacity: Double?
    var clip: String?
}

struct ClaudeGraph: Codable, Hashable {
    var origin: [Double]
    var unit: [Double]
    var xrange: [Double]
    var yrange: [Double]
}

struct ClaudeItem: Codable, Identifiable, Hashable {
    var id: String
    var type: String
    var title: String?
    var rev: Int?
    var autoplay: Bool?
    var poster: String?
    var posterAt: String?
    var logs: [String]?
    var points: [[Double]]?
    var from: [Double]?
    var to: [Double]?
    var center: [Double]?
    var rx: Double?
    var ry: Double?
    var x: Double?
    var y: Double?
    var w: Double?
    var h: Double?
    var text: String?
    var size: Double?
    var color: String?
    var width: Double?
    var fill: String?
    var d: String?
    var closed: Bool?
    var dashed: Bool?
    var latex: String?
    var smooth: Bool?
    var bend: Double?
    var halfHead: Bool?
    var group: String?
    var label: String?
    var revealed: Bool?
    var smiles: String?
    var head: String?
    var headFilled: Bool?
    var headD: String?
    var showCarbons: Bool?
    var explicitH: Bool?
    var atoms: [String: [Double]]?
    var elements: [String: String]?
    var parts: [ClaudePart]?
    var graph: ClaudeGraph?
    var origin: [Double]?
    var vertex: [Double]?
    var at: [Double]?
    var axes: String?
    var name: String?
    var radius: Double?
    var filled: Bool?
    var labelPos: String?
    var rightAngle: Bool?
    var rotation: Double?
    var rotationCenter: [Double]?
    var fillPattern: String?
    var patternSpacing: Double?
    var patternAngle: Double?
    var coils: Int?
    var amplitude: Double?
    var side: String?
    var hatchLength: Double?
    var spacing: Double?
    var fit: String?
    var opacity: Double?
    var alt: String?
    var file: String?

    enum CodingKeys: String, CodingKey {
        case id, type, points, from, to, center, rx, ry, x, y, w, h, text, size, color, width, fill, d, closed, dashed, latex, smooth, bend, group, label, revealed, smiles, parts, graph, origin, vertex, at, axes, name, radius, filled
        case fit, opacity, alt
        case file, title, rev, autoplay, poster, posterAt, logs
        case head
        case headFilled = "head_filled"
        case headD = "head_d"
        case showCarbons = "show_carbons"
        case explicitH = "explicit_h"
        case atoms, elements
        case halfHead = "half_head"
        case labelPos = "label_pos"
        case rightAngle = "right_angle"
        case rotation, coils, amplitude, side, spacing
        case rotationCenter = "rotation_center"
        case fillPattern = "fill_pattern"
        case patternSpacing = "pattern_spacing"
        case patternAngle = "pattern_angle"
        case hatchLength = "hatch_length"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
        autoplay = try c.decodeIfPresent(Bool.self, forKey: .autoplay)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        posterAt = try c.decodeIfPresent(String.self, forKey: .posterAt)
        logs = try c.decodeIfPresent([String].self, forKey: .logs)
        // Plot x/y are expressions and plot/shade from/to are scalar intervals.
        // Their prepared parts carry all client geometry; don't decode them as
        // the point coordinates used by older drawing types.
        if type != "plot" && type != "shade" {
            x = try c.decodeIfPresent(Double.self, forKey: .x)
            y = try c.decodeIfPresent(Double.self, forKey: .y)
            from = try c.decodeIfPresent([Double].self, forKey: .from)
            to = try c.decodeIfPresent([Double].self, forKey: .to)
        }
        points = try c.decodeIfPresent([[Double]].self, forKey: .points)
        center = try c.decodeIfPresent([Double].self, forKey: .center)
        rx = try c.decodeIfPresent(Double.self, forKey: .rx)
        ry = try c.decodeIfPresent(Double.self, forKey: .ry)
        w = try c.decodeIfPresent(Double.self, forKey: .w)
        h = try c.decodeIfPresent(Double.self, forKey: .h)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        size = try c.decodeIfPresent(Double.self, forKey: .size)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        width = try c.decodeIfPresent(Double.self, forKey: .width)
        fill = try c.decodeIfPresent(String.self, forKey: .fill)
        d = try c.decodeIfPresent(String.self, forKey: .d)
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed)
        dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed)
        latex = try c.decodeIfPresent(String.self, forKey: .latex)
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth)
        bend = try c.decodeIfPresent(Double.self, forKey: .bend)
        halfHead = try c.decodeIfPresent(Bool.self, forKey: .halfHead)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        revealed = try c.decodeIfPresent(Bool.self, forKey: .revealed)
        smiles = try c.decodeIfPresent(String.self, forKey: .smiles)
        head = try c.decodeIfPresent(String.self, forKey: .head)
        headFilled = try c.decodeIfPresent(Bool.self, forKey: .headFilled)
        headD = try c.decodeIfPresent(String.self, forKey: .headD)
        showCarbons = try c.decodeIfPresent(Bool.self, forKey: .showCarbons)
        explicitH = try c.decodeIfPresent(Bool.self, forKey: .explicitH)
        atoms = try c.decodeIfPresent([String: [Double]].self, forKey: .atoms)
        elements = try c.decodeIfPresent([String: String].self, forKey: .elements)
        parts = try c.decodeIfPresent([ClaudePart].self, forKey: .parts)
        graph = try c.decodeIfPresent(ClaudeGraph.self, forKey: .graph)
        origin = try c.decodeIfPresent([Double].self, forKey: .origin)
        vertex = try c.decodeIfPresent([Double].self, forKey: .vertex)
        at = try c.decodeIfPresent([Double].self, forKey: .at)
        axes = try c.decodeIfPresent(String.self, forKey: .axes)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        filled = try c.decodeIfPresent(Bool.self, forKey: .filled)
        labelPos = try c.decodeIfPresent(String.self, forKey: .labelPos)
        rightAngle = try c.decodeIfPresent(Bool.self, forKey: .rightAngle)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation)
        rotationCenter = try c.decodeIfPresent([Double].self, forKey: .rotationCenter)
        fillPattern = try c.decodeIfPresent(String.self, forKey: .fillPattern)
        patternSpacing = try c.decodeIfPresent(Double.self, forKey: .patternSpacing)
        patternAngle = try c.decodeIfPresent(Double.self, forKey: .patternAngle)
        coils = try c.decodeIfPresent(Int.self, forKey: .coils)
        amplitude = try c.decodeIfPresent(Double.self, forKey: .amplitude)
        side = try c.decodeIfPresent(String.self, forKey: .side)
        hatchLength = try c.decodeIfPresent(Double.self, forKey: .hatchLength)
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing)
        fit = try c.decodeIfPresent(String.self, forKey: .fit)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity)
        alt = try c.decodeIfPresent(String.self, forKey: .alt)
        file = try c.decodeIfPresent(String.self, forKey: .file)
    }
}

/// A page that sits on top of a PDF page. `page` is 1-based.
struct PDFRef: Codable, Hashable {
    var file: String
    var page: Int
}

struct Page: Codable, Identifiable, Hashable {
    var id: String
    var background: PageBackground
    var paper: PaperColor? = nil
    var paperSnapshotStale: Bool? = nil
    var strokeCount: Int? = nil
    var pdf: PDFRef?
    var snapshotVersion: Int
    var textBoxes: [TextBox]
    var claudeLayer: [ClaudeItem]
    var doubts: [Doubt]?
    var updatedAt: String
}

enum ISODate {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

struct Folder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// nil for a top-level folder.
    var parentId: String?
    var createdAt: String
    var updatedAt: String
}

struct Notebook: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var pages: [Page]
    var createdAt: String
    var updatedAt: String
    /// Claude asked to delete this notebook; the library asks the user to confirm.
    var deleteRequestedAt: String?
    /// nil when the notebook sits at the top level of the library.
    var folderId: String?
    /// Scratch pads delete themselves on the server at `expiresAt` (a week after the last edit) unless kept.
    var scratch: Bool?
    var expiresAt: String?

    var isScratch: Bool { scratch == true }
    var expiryDate: Date? { expiresAt.flatMap(ISODate.parse) }

    /// Latest change to the notebook or any page (ink upload, Claude's marks). ISO strings sort by time.
    var lastActivity: String { pages.map(\.updatedAt).reduce(updatedAt) { max($0, $1) } }

    var lastActivityDate: Date? { ISODate.parse(lastActivity) }

    var openDoubts: Int { pages.reduce(0) { $0 + ($1.doubts ?? []).filter(\.isOpen).count } }
}

struct ViewState: Codable {
    var notebookId: String?
    var pageId: String?
}

struct NotebookList: Codable {
    var notebooks: [Notebook]
    /// Missing from servers older than folders.
    var folders: [Folder]?
    var view: ViewState
}

/// Messages pushed over the /live websocket.
struct LiveEvent: Codable {
    var type: String
    var notebookId: String?
    var pageId: String?
}
