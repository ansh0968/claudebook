import Foundation
import CoreGraphics

/// Every page shares one logical coordinate space with the server, so Claude's coordinates map 1:1.
enum PageGeometry {
    static let width: CGFloat = 1000
    static let height: CGFloat = 1414
    static let size = CGSize(width: width, height: height)
    static let rect = CGRect(origin: .zero, size: size)
}

enum PageBackground: String, Codable {
    case blank, lined, grid, dotted
}

struct TextBox: Codable, Hashable {
    var text: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
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
struct ClaudeItem: Codable, Identifiable, Hashable {
    var id: String
    var type: String
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
    /// Arrowheads the server computed for arrow, path and svg items, in page coordinates.
    var headD: String?
    var showCarbons: Bool?
    var explicitH: Bool?
    var atoms: [String: [Double]]?
    var elements: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, type, points, from, to, center, rx, ry, x, y, w, h, text, size, color, width, fill, d, closed, dashed, latex, smooth, bend, group, label, revealed, smiles, head, atoms, elements
        case halfHead = "half_head"
        case headFilled = "head_filled"
        case headD = "head_d"
        case showCarbons = "show_carbons"
        case explicitH = "explicit_h"
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
    var pdf: PDFRef?
    var snapshotVersion: Int
    var textBoxes: [TextBox]
    var claudeLayer: [ClaudeItem]
    var doubts: [Doubt]?
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

    /// Latest change to the notebook or any page (ink upload, Claude's marks). ISO strings sort by time.
    var lastActivity: String { pages.map(\.updatedAt).reduce(updatedAt) { max($0, $1) } }

    var lastActivityDate: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: lastActivity) ?? ISO8601DateFormatter().date(from: lastActivity)
    }

    var openDoubts: Int { pages.reduce(0) { $0 + ($1.doubts ?? []).filter(\.isOpen).count } }
}

struct ViewState: Codable {
    var notebookId: String?
    var pageId: String?
}

struct NotebookList: Codable {
    var notebooks: [Notebook]
    var view: ViewState
}

/// Messages pushed over the /live websocket.
struct LiveEvent: Codable {
    var type: String
    var notebookId: String?
    var pageId: String?
}
