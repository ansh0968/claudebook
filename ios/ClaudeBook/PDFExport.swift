import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// Options chosen in the Export PDF popover before opening the iPad share sheet.
struct PDFExportOptions: Equatable {
    var includeClaudeInk = true
    var lightPaperForPrint = true
}

/// Captures the pages and title to export for a popover presentation.
struct PDFExportRequest: Identifiable {
    let id = UUID()
    var title: String
    var pages: [Page]
    /// Set when exporting a full notebook from the library shelf so online exports pick up fresh server marks.
    var refreshNotebookId: String? = nil
    /// Live per-page drawings flushed from an open canvas.
    var drawingOverrides: [String: PKDrawing] = [:]
}

enum PDFExportError: LocalizedError {
    case noPages

    var errorDescription: String? {
        switch self {
        case .noPages: return "There are no pages to export."
        }
    }
}

/// Renders notebook pages on-device as crisp 1000x1414 vector A4 PDFs.
@MainActor
enum PDFExporter {
    private struct PreparedPage {
        var style: PaperStyle
        var useDarkInk: Bool
        var inkImage: UIImage?
        var inkRect: CGRect
        var claudeItems: [ClaudeItem]
    }

    /// Strips path separators and illegal characters while keeping the notebook's readable title.
    static func sanitizedBaseName(for title: String) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasSuffix(".pdf") {
            cleaned = String(cleaned.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        cleaned = cleaned.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if cleaned.count > 120 {
            cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        return cleaned.isEmpty ? "Notebook" : cleaned
    }

    static func sanitizedFilename(for title: String) -> String {
        sanitizedBaseName(for: title) + ".pdf"
    }

    /// Generates vector PDF bytes at 1000 x 1414 units per page without mutating notebook state.
    /// Device-local rough work (`RoughStore`) and unresolved doubt markers (`Doubt`) are never drawn.
    static func renderPDF(
        pages: [Page],
        title: String,
        options: PDFExportOptions = PDFExportOptions(),
        appDark: Bool = false,
        invertPDFs: Bool = true,
        drawingOverrides: [String: PKDrawing] = [:],
        remoteDrawingLoader: ((String) async -> Data?)? = nil
    ) async throws -> Data {
        guard !pages.isEmpty else { throw PDFExportError.noPages }

        var prepared: [PreparedPage] = []
        prepared.reserveCapacity(pages.count)

        for page in pages {
            let pdfPage: CGPDFPage?
            if let ref = page.pdf {
                pdfPage = await PDFCache.page(ref)
            } else {
                pdfPage = nil
            }

            let drawing = await resolveDrawing(
                for: page.id,
                overrides: drawingOverrides,
                remoteDrawingLoader: remoteDrawingLoader
            )

            let style: PaperStyle
            let useDarkInk: Bool
            if options.lightPaperForPrint {
                style = PaperStyle(background: page.background, paper: .white, pdf: pdfPage, dark: false, invertPDF: false)
                useDarkInk = false
            } else {
                style = PaperStyle(background: page.background, paper: page.paper, pdf: pdfPage, dark: appDark, invertPDF: invertPDFs)
                useDarkInk = page.usesDarkInkPalette(appDark: appDark)
            }

            // Render PencilKit strokes over their tight bounds before opening the PDF context so
            // underlying PDF text and paper rulings remain native vector paths.
            var inkImage: UIImage?
            var inkRect = CGRect.zero
            if !drawing.strokes.isEmpty {
                let crop = drawing.bounds.insetBy(dx: -8, dy: -8).intersection(PageGeometry.rect).integral
                if !crop.isNull, crop.width > 0, crop.height > 0 {
                    inkRect = crop
                    UITraitCollection(userInterfaceStyle: useDarkInk ? .dark : .light).performAsCurrent {
                        inkImage = drawing.image(from: crop, scale: 2)
                    }
                }
            }

            let claudeItems = options.includeClaudeInk ? page.claudeLayer : []
            for file in Set(claudeItems.filter { $0.type == "image" }.compactMap(\.file)) {
                _ = await ImageCache.load(file)
            }

            prepared.append(PreparedPage(
                style: style,
                useDarkInk: useDarkInk,
                inkImage: inkImage,
                inkRect: inkRect,
                claudeItems: claudeItems
            ))
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: sanitizedBaseName(for: title),
            kCGPDFContextCreator as String: "ClaudeBook",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: PageGeometry.rect, format: format)
        return renderer.pdfData { pdfCtx in
            for entry in prepared {
                pdfCtx.beginPage()
                let cg = pdfCtx.cgContext
                cg.saveGState()
                PaperView.drawPaper(entry.style, in: cg)
                if let ink = entry.inkImage {
                    ink.draw(in: entry.inkRect)
                }
                for item in entry.claudeItems {
                    ClaudeRenderer.draw(item, dark: entry.useDarkInk, in: cg)
                }
                cg.restoreGState()
            }
        }
    }

    /// Writes the rendered PDF to a temporary directory under `<Notebook Title>.pdf` for `UIActivityViewController`.
    static func exportFile(
        pages: [Page],
        title: String,
        options: PDFExportOptions = PDFExportOptions(),
        appDark: Bool = false,
        invertPDFs: Bool = true,
        drawingOverrides: [String: PKDrawing] = [:],
        remoteDrawingLoader: ((String) async -> Data?)? = nil
    ) async throws -> URL {
        pruneTemporaryExports()
        let data = try await renderPDF(
            pages: pages,
            title: title,
            options: options,
            appDark: appDark,
            invertPDFs: invertPDFs,
            drawingOverrides: drawingOverrides,
            remoteDrawingLoader: remoteDrawingLoader
        )
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "exports/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: sanitizedFilename(for: title))
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func resolveDrawing(
        for pageId: String,
        overrides: [String: PKDrawing],
        remoteDrawingLoader: ((String) async -> Data?)?
    ) async -> PKDrawing {
        if let override = overrides[pageId] {
            return override
        }
        if LocalDrawings.exists(pageId) {
            return LocalDrawings.load(pageId) ?? PKDrawing()
        }
        guard !LocalDrawings.isDeleted(pageId), !PendingPageCreations.contains(pageId) else {
            return PKDrawing()
        }
        let loader = remoteDrawingLoader ?? { id in try? await API.current?.drawing(pageId: id) }
        if let data = await loader(pageId), let remote = try? PKDrawing(data: data) {
            if PendingUploads.revision(pageId) == nil && !LocalDrawings.exists(pageId) {
                LocalDrawings.save(remote, pageId: pageId)
            }
            return remote
        }
        return PKDrawing()
    }

    private static func pruneTemporaryExports() {
        let root = FileManager.default.temporaryDirectory.appending(path: "exports", directoryHint: .isDirectory)
        let keys: Set<URLResourceKey> = [.creationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries {
            if let created = (try? entry.resourceValues(forKeys: keys))?.creationDate, created < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

/// Compact popover shown before sharing so users can include/omit Claude's layer and choose print-light paper.
struct ExportPDFPopover: View {
    let request: PDFExportRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("invertPDFs") private var invertPDFs = true
    @State private var options = PDFExportOptions()
    @State private var exporting = false
    @State private var error: String?
    @State private var hostHolder = PopoverHostHolder()

    private var pageCountSummary: String {
        let count = request.pages.count
        return "\(count) page\(count == 1 ? "" : "s") · Vector A4 PDF"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Export PDF")
                            .font(Theme.title(.title3))
                            .foregroundStyle(Theme.ink)
                        Text("Vector")
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                    Text(pageCountSummary)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 28, height: 28)
                        .background(Theme.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(exporting)
                .accessibilityLabel("Close export options")
            }

            Divider().overlay(Theme.hairline)

            VStack(spacing: 14) {
                Toggle(isOn: $options.includeClaudeInk) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include Claude's ink")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Tutor notes, diagrams, and math")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                .tint(Theme.orange)
                .accessibilityIdentifier("export.includeClaudeInk")

                Toggle(isOn: $options.lightPaperForPrint) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Light paper for print")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Clean white background on dark pages")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                .tint(Theme.orange)
                .accessibilityIdentifier("export.lightPaper")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }

            Button {
                Task { await share() }
            } label: {
                HStack(spacing: 8) {
                    if exporting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(exporting ? "Preparing PDF…" : "Share PDF")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Theme.orange)
            .disabled(exporting || request.pages.isEmpty)
            .accessibilityIdentifier("export.share")
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.surface)
        .background(PopoverHostProbe(holder: hostHolder))
        .presentationCompactAdaptation(.popover)
    }

    private func share() async {
        guard !exporting else { return }
        exporting = true
        error = nil
        do {
            var exportPages = request.pages
            var exportTitle = request.title
            if let notebookId = request.refreshNotebookId,
               let latest = try? await API.current?.notebook(notebookId) {
                let merged = PendingPageCreations.merging(into: latest)
                if !merged.pages.isEmpty {
                    exportPages = merged.pages
                    exportTitle = merged.title
                }
            }
            let url = try await PDFExporter.exportFile(
                pages: exportPages,
                title: exportTitle,
                options: options,
                appDark: colorScheme == .dark,
                invertPDFs: invertPDFs,
                drawingOverrides: request.drawingOverrides
            )
            let anchor = hostHolder.captureAnchor()
            dismiss()
            await PDFShareSheet.present(
                url: url,
                from: anchor.presenter,
                sourceView: anchor.sourceView,
                sourceRect: anchor.sourceRect
            )
        } catch {
            self.error = error.localizedDescription
            exporting = false
        }
    }
}

private final class PopoverHostHolder {
    weak var viewController: UIViewController?

    @MainActor
    func captureAnchor() -> (presenter: UIViewController?, sourceView: UIView?, sourceRect: CGRect) {
        var root = viewController
        while let parent = root?.parent {
            root = parent
        }
        let pop = root?.popoverPresentationController
        return (root?.presentingViewController, pop?.sourceView, pop?.sourceRect ?? .zero)
    }
}

private struct PopoverHostProbe: UIViewControllerRepresentable {
    let holder: PopoverHostHolder

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        holder.viewController = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        holder.viewController = uiViewController
    }
}

/// Presents `UIActivityViewController` on iPadOS after any active popover finishes dismissing.
@MainActor
enum PDFShareSheet {
    static func present(
        url: URL,
        from preferredPresenter: UIViewController?,
        sourceView: UIView?,
        sourceRect: CGRect
    ) async {
        guard let presenter = preferredPresenter ?? topViewController() else { return }

        // Wait briefly for the Export PDF popover dismissal animation to complete.
        for step in 0..<30 {
            guard presenter.presentedViewController != nil else { break }
            if step == 10, let presented = presenter.presentedViewController, !presented.isBeingDismissed {
                presented.dismiss(animated: false)
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard presenter.presentedViewController == nil else { return }

        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = activity.popoverPresentationController {
            if let sourceView, sourceView.window != nil {
                pop.sourceView = sourceView
                pop.sourceRect = sourceRect.isEmpty ? sourceView.bounds : sourceRect
            } else {
                pop.sourceView = presenter.view
                pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: 60, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
        }
        presenter.present(activity, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
