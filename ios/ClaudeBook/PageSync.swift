import PDFKit
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

    static func load(_ pageId: String) -> PKDrawing? {
        guard let data = try? Data(contentsOf: url(pageId)) else { return nil }
        return try? PKDrawing(data: data)
    }

    static func save(_ drawing: PKDrawing, pageId: String) {
        try? drawing.dataRepresentation().write(to: url(pageId), options: .atomic)
    }
}

/// Renders what the user wrote and reads their handwriting, so Claude gets an image plus text positions.
enum PageSnapshot {
    /// Paper (or PDF page) + user ink at 1000x1414, no Claude layer (the server adds that itself).
    /// Rendered at 2x so Claude can zoom in and still read small handwriting.
    static func png(drawing: PKDrawing, background: PageBackground, pdf: PDFPage? = nil) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: PageGeometry.size, format: format).image { ctx in
            PaperView.drawPaper(background, pdf: pdf, pixelScale: 2, in: ctx.cgContext)
            drawing.image(from: PageGeometry.rect, scale: 2).draw(in: PageGeometry.rect)
        }
        return image.pngData() ?? Data()
    }

    /// On-device handwriting recognition. Runs on ink alone so ruled lines don't confuse Vision.
    static func recognizeText(drawing: PKDrawing) async -> [TextBox] {
        guard !drawing.strokes.isEmpty else { return [] }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: PageGeometry.size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(PageGeometry.rect)
            drawing.image(from: PageGeometry.rect, scale: 2).draw(in: PageGeometry.rect)
        }
        guard let cg = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            return (request.results ?? []).compactMap { o -> TextBox? in
                guard let text = o.topCandidates(1).first?.string else { return nil }
                // Vision boxes are normalized with the origin at the bottom left.
                let b = o.boundingBox
                return TextBox(text: text,
                               x: b.minX * PageGeometry.width,
                               y: (1 - b.maxY) * PageGeometry.height,
                               w: b.width * PageGeometry.width,
                               h: b.height * PageGeometry.height)
            }
        }.value
    }
}
