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
}

struct Page: Codable, Identifiable, Hashable {
    var id: String
    var background: PageBackground
    var snapshotVersion: Int
    var textBoxes: [TextBox]
    var claudeLayer: [ClaudeItem]
    var updatedAt: String
}

struct Notebook: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var pages: [Page]
    var createdAt: String
    var updatedAt: String
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
