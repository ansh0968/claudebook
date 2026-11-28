import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import ClaudeBook

final class PDFExportTests: XCTestCase {
    func testFilenameSanitizationKeepsNotebookTitleAndStripsUnsafeCharacters() async {
        await MainActor.run {
            XCTAssertEqual(PDFExporter.sanitizedFilename(for: "Organic Chemistry"), "Organic Chemistry.pdf")
            XCTAssertEqual(PDFExporter.sanitizedFilename(for: "Lab / Guide : Week 1.pdf"), "Lab - Guide - Week 1.pdf")
            XCTAssertEqual(PDFExporter.sanitizedFilename(for: "   \n\t  "), "Notebook.pdf")
        }
    }

    @MainActor
    func testVectorPDFExportPreservesDimensionsPageCountAndSourceVectorText() async throws {
        let pdfFile = "test-pdf-" + UUID().uuidString
        let sourceData = makeSampleVectorPDF(texts: [
            "SN2 Nucleophilic Substitution Handout",
            "Elimination E2 Reaction Coordinate",
        ])
        PDFCache.store(sourceData, file: pdfFile)
        defer { PDFCache.remove(pdfFile) }

        var page1 = Page.blank(background: .blank)
        page1.pdf = PDFRef(file: pdfFile, page: 1)
        let page2 = Page.blank(background: .grid)
        var page3 = Page.blank(background: .blank)
        page3.pdf = PDFRef(file: pdfFile, page: 2)
        let allIds = [page1.id, page2.id, page3.id]
        defer { LocalDrawings.remove(allIds) }

        LocalDrawings.save(makeHorizontalStroke(y: 700, color: .systemBlue), pageId: page1.id)
        LocalDrawings.save(PKDrawing(), pageId: page2.id)
        LocalDrawings.save(PKDrawing(), pageId: page3.id)

        let url = try await PDFExporter.exportFile(
            pages: [page1, page2, page3],
            title: "Organic Chemistry"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "Organic Chemistry.pdf")
        let exported = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(exported.pageCount, 3)
        for index in 0..<exported.pageCount {
            let bounds = try XCTUnwrap(exported.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, 1000, accuracy: 0.5)
            XCTAssertEqual(bounds.height, 1414, accuracy: 0.5)
        }
        XCTAssertTrue(exported.page(at: 0)?.string?.contains("SN2 Nucleophilic Substitution Handout") == true)
        XCTAssertTrue(exported.page(at: 2)?.string?.contains("Elimination E2 Reaction Coordinate") == true)

        // Exporting a single selected page outputs only that page while keeping vector text intact.
        let singleData = try await PDFExporter.renderPDF(pages: [page3], title: "Organic Chemistry")
        let singleDoc = try XCTUnwrap(PDFDocument(data: singleData))
        XCTAssertEqual(singleDoc.pageCount, 1)
        XCTAssertTrue(singleDoc.page(at: 0)?.string?.contains("Elimination E2 Reaction Coordinate") == true)
    }

    @MainActor
    func testTutorLayerToggleOmitsClaudeInkWithoutMutatingPageAndExcludesDoubtsAndRoughWork() async throws {
        var page = Page.blank(background: .blank)
        let claudeRect = try JSONDecoder().decode(
            ClaudeItem.self,
            from: Data(#"{"id":"c1","type":"rect","x":200,"y":200,"w":240,"h":240,"color":"#E5484D","fill":"#E5484D"}"#.utf8)
        )
        page.claudeLayer = [claudeRect]
        page.doubts = [
            Doubt(
                id: "d1",
                pageId: page.id,
                region: PageRegion(x: 680, y: 220, w: 160, h: 160),
                createdAt: page.updatedAt,
                resolvedAt: nil
            )
        ]

        let roughStroke = makeHorizontalStroke(y: 320, color: .systemGreen)
        RoughStore.save([RoughSheet(ink: roughStroke.dataRepresentation(), strokes: 1)], pageId: page.id)
        LocalDrawings.save(PKDrawing(), pageId: page.id)
        defer {
            RoughStore.remove([page.id])
            LocalDrawings.remove([page.id])
        }

        let withClaude = try await PDFExporter.renderPDF(
            pages: [page],
            title: "Tutor Ink Test",
            options: PDFExportOptions(includeClaudeInk: true, lightPaperForPrint: true)
        )
        let withClaudePixels = try rasterizePDFPage(withClaude, pageIndex: 0)
        let claudeSpotOn = pixelRGB(in: withClaudePixels, at: CGPoint(x: 320, y: 320))
        XCTAssertGreaterThan(claudeSpotOn.r, 0.75)
        XCTAssertLessThan(claudeSpotOn.g, 0.45)

        // Open doubt badge sits near (minX - 18, minY - 18) = (662, 202) when drawn on screen; export must omit it.
        let doubtBadgeSpot = pixelRGB(in: withClaudePixels, at: CGPoint(x: 676, y: 216))
        XCTAssertGreaterThan(doubtBadgeSpot.r, 0.95)
        XCTAssertGreaterThan(doubtBadgeSpot.g, 0.95)
        XCTAssertGreaterThan(doubtBadgeSpot.b, 0.95)

        let withoutClaude = try await PDFExporter.renderPDF(
            pages: [page],
            title: "Tutor Ink Test",
            options: PDFExportOptions(includeClaudeInk: false, lightPaperForPrint: true)
        )
        let withoutClaudePixels = try rasterizePDFPage(withoutClaude, pageIndex: 0)
        let claudeSpotOff = pixelRGB(in: withoutClaudePixels, at: CGPoint(x: 320, y: 320))
        XCTAssertGreaterThan(claudeSpotOff.r, 0.95)
        XCTAssertGreaterThan(claudeSpotOff.g, 0.95)
        XCTAssertGreaterThan(claudeSpotOff.b, 0.95)
        XCTAssertEqual(page.claudeLayer.count, 1, "Omitting tutor ink during export must never mutate page.claudeLayer")
    }

    @MainActor
    func testLightPaperForPrintForcesWhitePaperInDarkModeWhileAllowingDarkPaperWhenDisabled() async throws {
        let page = Page.blank(background: .lined, paper: .black)
        LocalDrawings.save(PKDrawing(), pageId: page.id)
        defer { LocalDrawings.remove([page.id]) }

        let printLight = try await PDFExporter.renderPDF(
            pages: [page],
            title: "Dark Paper Print",
            options: PDFExportOptions(includeClaudeInk: true, lightPaperForPrint: true),
            appDark: true
        )
        let lightImage = try rasterizePDFPage(printLight, pageIndex: 0)
        let lightCorner = pixelRGB(in: lightImage, at: CGPoint(x: 12, y: 12))
        XCTAssertGreaterThan(lightCorner.r, 0.95)
        XCTAssertGreaterThan(lightCorner.g, 0.95)
        XCTAssertGreaterThan(lightCorner.b, 0.95)

        let preservedDark = try await PDFExporter.renderPDF(
            pages: [page],
            title: "Dark Paper Kept",
            options: PDFExportOptions(includeClaudeInk: true, lightPaperForPrint: false),
            appDark: true
        )
        let darkImage = try rasterizePDFPage(preservedDark, pageIndex: 0)
        let darkCorner = pixelRGB(in: darkImage, at: CGPoint(x: 12, y: 12))
        XCTAssertLessThan(darkCorner.r, 0.2)
        XCTAssertLessThan(darkCorner.g, 0.2)
        XCTAssertLessThan(darkCorner.b, 0.2)
    }

    @MainActor
    func testRemoteDrawingFallbackAndOfflineCachedExport() async throws {
        let remotePage = Page.blank(background: .blank)
        let cachedPage = Page.blank(background: .blank)
        defer { LocalDrawings.remove([remotePage.id, cachedPage.id]) }

        let remoteStroke = makeHorizontalStroke(y: 420, color: .systemRed, width: 16)
        LocalDrawings.save(makeHorizontalStroke(y: 860, color: .systemBlue, width: 16), pageId: cachedPage.id)

        var requestedRemoteIds: [String] = []
        let exported = try await PDFExporter.renderPDF(
            pages: [remotePage, cachedPage],
            title: "Hybrid Sync Export",
            remoteDrawingLoader: { id in
                requestedRemoteIds.append(id)
                return id == remotePage.id ? remoteStroke.dataRepresentation() : nil
            }
        )
        XCTAssertEqual(requestedRemoteIds, [remotePage.id], "Cached local pages should not require a network fetch")
        let remoteImage = try rasterizePDFPage(exported, pageIndex: 0)
        let strokePixel = pixelRGB(in: remoteImage, at: CGPoint(x: 250, y: 420))
        XCTAssertGreaterThan(strokePixel.r, 0.6)
        XCTAssertLessThan(strokePixel.b, 0.5)

        // Offline export of cached pages succeeds even if remote loader returns nil.
        let offlineData = try await PDFExporter.renderPDF(
            pages: [cachedPage],
            title: "Offline Export",
            remoteDrawingLoader: { _ in nil }
        )
        XCTAssertEqual(PDFDocument(data: offlineData)?.pageCount, 1)
    }

    @MainActor
    func testCurrentDrawingsFlushesUnsavedCanvasStrokesImmediately() {
        let page = Page.blank(background: .lined)
        defer { LocalDrawings.remove([page.id]) }
        LocalDrawings.save(PKDrawing(), pageId: page.id)

        let notebook = Notebook(
            id: UUID().uuidString,
            title: "Flush before export",
            pages: [page],
            createdAt: page.updatedAt,
            updatedAt: page.updatedAt
        )
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.setNotebook(notebook)
        controller.addTestStroke()

        let flushed = controller.currentDrawings()
        XCTAssertFalse(flushed[page.id]?.strokes.isEmpty ?? true)
    }

    // MARK: - Helpers

    private func makeSampleVectorPDF(texts: [String]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for line in texts {
                ctx.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                    .foregroundColor: UIColor.black,
                ]
                (line as NSString).draw(at: CGPoint(x: 64, y: 120), withAttributes: attrs)
            }
        }
    }

    private func makeHorizontalStroke(y: CGFloat, color: UIColor, width: CGFloat = 10) -> PKDrawing {
        let points = stride(from: 120.0, through: 420.0, by: 15.0).enumerated().map { idx, x in
            PKStrokePoint(
                location: CGPoint(x: x, y: Double(y)),
                timeOffset: Double(idx) * 0.01,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let stroke = PKStroke(
            ink: PKInk(.pen, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date())
        )
        return PKDrawing(strokes: [stroke])
    }

    private func rasterizePDFPage(_ data: Data, pageIndex: Int) throws -> UIImage {
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let pdfPage = try XCTUnwrap(doc.page(at: pageIndex)?.pageRef)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: PageGeometry.size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(PageGeometry.rect)
            cg.saveGState()
            cg.translateBy(x: 0, y: PageGeometry.height)
            cg.scaleBy(x: 1, y: -1)
            cg.drawPDFPage(pdfPage)
            cg.restoreGState()
        }
    }

    private func pixelRGB(in image: UIImage, at point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let cg = image.cgImage else { return (0, 0, 0) }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0, 0, 0)
        }
        ctx.translateBy(x: -floor(point.x), y: -(CGFloat(cg.height) - 1 - floor(point.y)))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }
}
