import PencilKit
import UIKit
import Vision

/// Local copy of each page's PencilKit drawing, so the app works offline and opens instantly.
enum LocalDrawings {
    private static var dir: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "drawings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(_ pageId: String) -> URL { dir.appending(path: "\(pageId).pkdrawing") }

    private static let deletedKey = "deletedPageIds"
    static func isDeleted(_ id: String) -> Bool { Set(UserDefaults.standard.stringArray(forKey: deletedKey) ?? []).contains(id) }

    /// Only called after the server confirms deletion. Late saves and upload retries
    /// must not recreate a drawing when an editor disappears during that deletion.
    static func remove(_ ids: [String]) {
        var deleted = Set(UserDefaults.standard.stringArray(forKey: deletedKey) ?? [])
        deleted.formUnion(ids)
        UserDefaults.standard.set(Array(deleted), forKey: deletedKey)
        PendingUploads.all.subtract(ids)
        for id in ids { try? FileManager.default.removeItem(at: url(id)) }
    }

    static func exists(_ pageId: String) -> Bool { FileManager.default.fileExists(atPath: url(pageId).path) }

    static func load(_ pageId: String) -> PKDrawing? {
        guard !isDeleted(pageId), let data = try? Data(contentsOf: url(pageId)) else { return nil }
        return try? PKDrawing(data: data)
    }

    static func save(_ drawing: PKDrawing, pageId: String) {
        guard !isDeleted(pageId) else { return }
        try? drawing.dataRepresentation().write(to: url(pageId), options: .atomic)
        NotificationCenter.default.post(name: .localDrawingChanged, object: nil, userInfo: ["pageId": pageId])
    }
}

/// Pages whose ink changed but hasn't reached the server yet. Kept on disk so a page drawn on just
/// before the app was killed still uploads next time its notebook opens.
enum PendingUploads {
    private static let key = "pendingUploads"

    static var all: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.filter { !LocalDrawings.isDeleted($0) }), forKey: key) }
    }
}

/// Renders what the user wrote and reads their handwriting, so Claude gets an image plus text positions.
enum PageSnapshot {
    /// Paper (or PDF page) + user ink at 1000x1414, no Claude layer (the server adds that itself).
    /// Rendered at 2x. Legacy paper keeps light snapshots; explicit dark paper preserves its real
    /// background and dark ink appearance, so light ink remains visible to Claude.
    static func png(drawing: PKDrawing, background: PageBackground, paper: PaperColor? = nil, pdf: CGPDFPage? = nil) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        var data = Data()
        UITraitCollection(userInterfaceStyle: paper?.isDark == true ? .dark : .light).performAsCurrent {
            let image = UIGraphicsImageRenderer(size: PageGeometry.size, format: format).image { ctx in
                PaperView.drawPaper(PaperStyle(background: background, paper: paper, pdf: pdf), in: ctx.cgContext)
                drawing.image(from: PageGeometry.rect, scale: 2).draw(in: PageGeometry.rect)
            }
            data = image.pngData() ?? Data()
        }
        return data
    }

    /// On-device handwriting recognition. Runs on ink alone so ruled lines don't confuse Vision.
    static func recognizeText(drawing: PKDrawing) async -> [TextBox] {
        guard !drawing.strokes.isEmpty else { return [] }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = UIGraphicsImageRenderer(size: PageGeometry.size, format: format).image { _ in
                UIColor.white.setFill()
                UIRectFill(PageGeometry.rect)
                drawing.image(from: PageGeometry.rect, scale: 2).draw(in: PageGeometry.rect)
            }
        }
        guard let cg = image?.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Language correction turns mathematical symbols into plausible words.
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            return (request.results ?? []).compactMap { o -> TextBox? in
                let candidates = o.topCandidates(3)
                guard let best = candidates.first else { return nil }
                // Vision boxes are normalized with the origin at the bottom left.
                let b = o.boundingBox
                return TextBox(text: best.string,
                               x: b.minX * PageGeometry.width,
                               y: (1 - b.maxY) * PageGeometry.height,
                               w: b.width * PageGeometry.width,
                               h: b.height * PageGeometry.height,
                               alts: candidates.map { $0.string },
                               confidence: Double(best.confidence))
            }
        }.value
    }
}
