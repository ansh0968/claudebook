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

    private static let legacyDeletedKey = "deletedPageIds"
    private static let confirmedDeletedKey = "confirmedDeletedPageIds"
    private static var legacyDeletedIds = Set(UserDefaults.standard.stringArray(forKey: legacyDeletedKey) ?? [])
    private(set) static var confirmedDeletedIds = Set(UserDefaults.standard.stringArray(forKey: confirmedDeletedKey) ?? [])

    static func isDeleted(_ id: String) -> Bool { confirmedDeletedIds.contains(id) || legacyDeletedIds.contains(id) }

    /// Older builds also marked a page deleted on upload 404. A server-listed page
    /// can be written to again, while new authoritative tombstones stay in force.
    static func reconcileLegacyDeletions(livePageIds: Set<String>) {
        let previous = legacyDeletedIds
        legacyDeletedIds.subtract(livePageIds)
        if legacyDeletedIds != previous {
            UserDefaults.standard.set(Array(legacyDeletedIds), forKey: legacyDeletedKey)
        }
    }

    /// Only called after the server confirms deletion. Late saves and upload retries
    /// must not recreate a drawing when an editor disappears during that deletion.
    static func remove(_ ids: [String]) {
        confirmedDeletedIds.formUnion(ids)
        UserDefaults.standard.set(Array(confirmedDeletedIds), forKey: confirmedDeletedKey)
        PendingUploads.all.subtract(ids)
        for id in ids { try? FileManager.default.removeItem(at: url(id)) }
    }

    static func exists(_ pageId: String) -> Bool { FileManager.default.fileExists(atPath: url(pageId).path) }

    static func load(_ pageId: String) -> PKDrawing? {
        guard !isDeleted(pageId), let data = try? Data(contentsOf: url(pageId)) else { return nil }
        return try? PKDrawing(data: data)
    }

    @discardableResult
    static func save(_ drawing: PKDrawing, pageId: String) -> Bool {
        guard !isDeleted(pageId) else { return false }
        do {
            try drawing.dataRepresentation().write(to: url(pageId), options: .atomic)
            NotificationCenter.default.post(name: .localDrawingChanged, object: nil, userInfo: ["pageId": pageId])
            return true
        } catch { return false }
    }
}

private enum SyncQueueFile {
    private static let directory = URL.applicationSupportDirectory.appending(path: "sync", directoryHint: .isDirectory)

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appending(path: name), options: .atomic)
    }
}

struct ClientSequence: Codable {
    let clientId: String
    private(set) var sequence: Int

    private static let file = "client-sequence.json"
    @MainActor private static var last = SyncQueueFile.read(ClientSequence.self, file)
        ?? ClientSequence(clientId: UUID().uuidString, sequence: 0)

    @MainActor static func next() throws -> ClientSequence {
        var next = last
        next.sequence += 1
        try SyncQueueFile.write(next, file)
        last = next
        return next
    }
}

/// Pending generations stay on disk through rendering, upload, and app termination.
enum PendingUploads {
    struct Revision: Codable, Equatable {
        var id = UUID()
        var vectorBackedUp = false
    }

    private static let file = "ink.json"
    private static let legacyKey = "pendingUploads"
    private static var revisions = SyncQueueFile.read([String: Revision].self, file)
        ?? Dictionary(uniqueKeysWithValues: Set(UserDefaults.standard.stringArray(forKey: legacyKey) ?? []).map { ($0, Revision()) })
    private static var inFlight = Set<String>()

    @discardableResult
    private static func store(_ updated: [String: Revision]) -> Bool {
        do {
            try SyncQueueFile.write(updated, file)
            revisions = updated
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return true
        } catch { return false }
    }

    /// The setter is used by confirmed deletions. Adding an already queued page leaves its revision alone.
    static var all: Set<String> {
        get { Set(revisions.keys.filter { !LocalDrawings.isDeleted($0) }) }
        set {
            var updated = revisions.filter { newValue.contains($0.key) && !LocalDrawings.isDeleted($0.key) }
            for id in newValue where updated[id] == nil && !LocalDrawings.isDeleted(id) { updated[id] = Revision() }
            if updated != revisions { store(updated) }
        }
    }

    @discardableResult
    static func mark(_ ids: [String], replacing: Bool = true) -> Bool {
        var updated = revisions
        for id in ids where !LocalDrawings.isDeleted(id) && (replacing || updated[id] == nil) {
            updated[id] = Revision()
        }
        return updated == revisions || store(updated)
    }

    static func revision(_ id: String) -> Revision? {
        LocalDrawings.isDeleted(id) ? nil : revisions[id]
    }

    static func begin(_ id: String) -> Bool { inFlight.insert(id).inserted }
    static func end(_ id: String) { inFlight.remove(id) }

    static func acknowledge(_ id: String, revision: Revision, vectorOnly: Bool) {
        guard self.revision(id) == revision else { return }
        var updated = revisions
        if vectorOnly { updated[id]?.vectorBackedUp = true } else { updated.removeValue(forKey: id) }
        store(updated)
    }
}

/// A locally writable page whose server creation may still need to be retried.
enum PendingPageCreations {
    struct Creation: Codable {
        var page: Page
        var afterPageId: String?
        var afterIndex: Int

        func insertionIndex(in pages: [Page]) -> Int {
            if let afterPageId, let index = pages.firstIndex(where: { $0.id == afterPageId }) { return index + 1 }
            return min(pages.count, max(0, afterIndex + 1))
        }
    }

    private struct Draft: Codable {
        var notebook: Notebook
        var creations: [Creation]
    }

    private static let file = "page-creations.json"
    private static var drafts = SyncQueueFile.read([String: Draft].self, file) ?? [:]

    static func contains(_ pageId: String) -> Bool {
        drafts.values.contains { $0.creations.contains { $0.page.id == pageId } }
    }

    static func pending(_ notebookId: String) -> [Creation] { drafts[notebookId]?.creations ?? [] }

    /// Exposes only unsynced pages if a notebook is unavailable, including after a relaunch.
    static var localNotebooks: [Notebook] { drafts.values.map { merging(into: $0.notebook) } }

    static func localNotebook(_ id: String) -> Notebook? { drafts[id].map { merging(into: $0.notebook) } }

    static func add(_ creation: Creation, to notebook: Notebook) throws {
        var updated = drafts
        var shell = notebook
        shell.pages = []
        shell.folderId = nil
        shell.deleteRequestedAt = nil
        if updated[notebook.id] == nil { updated[notebook.id] = Draft(notebook: shell, creations: []) }
        updated[notebook.id]?.creations.append(creation)
        try SyncQueueFile.write(updated, file)
        drafts = updated
    }

    static func confirm(_ pageId: String, in notebookId: String) throws {
        guard pending(notebookId).contains(where: { $0.page.id == pageId }) else { return }
        var updated = drafts
        updated[notebookId]?.creations.removeAll { $0.page.id == pageId }
        if updated[notebookId]?.creations.isEmpty == true { updated.removeValue(forKey: notebookId) }
        try SyncQueueFile.write(updated, file)
        drafts = updated
    }

    /// A lost create response can leave a draft for a page the server later deleted.
    /// Keep local ink, retry records, and pages that may still have an unfinished stroke.
    static func pruneDeletedBlankPages(_ ids: [String], activePageIds: Set<String>) throws {
        let candidates = Set(ids).subtracting(activePageIds)
        guard !candidates.isEmpty else { return }
        var updated = drafts
        var changed = false
        for (id, var draft) in drafts {
            let count = draft.creations.count
            draft.creations.removeAll { creation in
                let pageId = creation.page.id
                guard candidates.contains(pageId), PendingUploads.revision(pageId) == nil else { return false }
                return !LocalDrawings.exists(pageId)
            }
            guard draft.creations.count != count else { continue }
            changed = true
            updated[id] = draft.creations.isEmpty ? nil : draft
        }
        guard changed else { return }
        try SyncQueueFile.write(updated, file)
        drafts = updated
    }

    static func merging(into notebook: Notebook) -> Notebook {
        var result = notebook
        for creation in pending(notebook.id) where !result.pages.contains(where: { $0.id == creation.page.id }) {
            result.pages.insert(creation.page, at: creation.insertionIndex(in: result.pages))
        }
        return result
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
