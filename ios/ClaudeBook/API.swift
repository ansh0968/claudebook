import Foundation
import Security

/// Server address + shared secret. The secret lives in the Keychain.
enum Credentials {
    private static let urlKey = "serverURL"
    private static let account = "claudebook-secret"

    /// CI's simulator smoke test points the app at a throwaway local server through these.
    private static let env = ProcessInfo.processInfo.environment

    static var serverURL: String {
        get { env["CLAUDEBOOK_SERVER"] ?? UserDefaults.standard.string(forKey: urlKey) ?? "https://book.clarifiq.in" }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    static var secret: String {
        get {
            if let s = env["CLAUDEBOOK_SECRET"] { return s }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static var isConfigured: Bool { !secret.isEmpty && URL(string: serverURL) != nil }
}

struct APIError: LocalizedError {
    var status: Int
    var body: String
    var errorDescription: String? { "Server said \(status): \(body)" }
}

/// Thin REST client for the ClaudeBook server.
struct API {
    var base: URL
    var secret: String

    static var current: API? {
        guard Credentials.isConfigured, let url = URL(string: Credentials.serverURL) else { return nil }
        return API(base: url, secret: Credentials.secret)
    }

    private func request(_ path: String, method: String = "GET", json: Encodable? = nil, body: Data? = nil, contentType: String = "application/octet-stream", query: [URLQueryItem] = []) async throws -> Data {
        var url = base.appending(path: "api").appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(json)
        } else if let body {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    func notebooks() async throws -> NotebookList {
        try decode(NotebookList.self, await request("notebooks"))
    }

    func notebook(_ id: String) async throws -> Notebook {
        try decode(Notebook.self, await request("notebooks/\(id)"))
    }

    func createNotebook(title: String, background: PageBackground, folderId: String? = nil, scratch: Bool = false) async throws -> Notebook {
        struct Body: Encodable { var title: String; var pages: Int; var background: PageBackground; var folderId: String?; var scratch: Bool? }
        let body = Body(title: title, pages: 1, background: background, folderId: folderId, scratch: scratch ? true : nil)
        return try decode(Notebook.self, await request("notebooks", method: "POST", json: body))
    }

    func renameNotebook(_ id: String, title: String) async throws {
        struct Body: Encodable { var title: String }
        _ = try await request("notebooks/\(id)", method: "PATCH", json: Body(title: title))
    }

    /// nil moves the notebook to the top level.
    func moveNotebook(_ id: String, to folderId: String?) async throws {
        struct Body: Encodable { var folderId: String }
        _ = try await request("notebooks/\(id)", method: "PATCH", json: Body(folderId: folderId ?? ""))
    }

    /// Turns a scratch pad into a normal notebook so it's never deleted.
    func keepScratchPad(_ id: String, title: String, folderId: String?) async throws {
        struct Body: Encodable { var title: String; var folderId: String; var scratch = false }
        _ = try await request("notebooks/\(id)", method: "PATCH", json: Body(title: title, folderId: folderId ?? ""))
    }

    func createFolder(name: String, parentId: String?) async throws -> Folder {
        struct Body: Encodable { var name: String; var parentId: String? }
        return try decode(Folder.self, await request("folders", method: "POST", json: Body(name: name, parentId: parentId)))
    }

    func renameFolder(_ id: String, name: String) async throws {
        struct Body: Encodable { var name: String }
        _ = try await request("folders/\(id)", method: "PATCH", json: Body(name: name))
    }

    /// nil moves the folder to the top level.
    func moveFolder(_ id: String, to parentId: String?) async throws {
        struct Body: Encodable { var parentId: String }
        _ = try await request("folders/\(id)", method: "PATCH", json: Body(parentId: parentId ?? ""))
    }

    /// Notebooks and folders inside move up to the deleted folder's parent.
    func deleteFolder(_ id: String) async throws {
        _ = try await request("folders/\(id)", method: "DELETE")
    }

    func deleteNotebook(_ id: String) async throws -> [String]? {
        struct Deleted: Decodable { var deletedPageIds: [String]? }
        return try decode(Deleted.self, await request("notebooks/\(id)", method: "DELETE")).deletedPageIds
    }

    /// The user kept a notebook Claude asked to delete.
    func cancelDeleteRequest(_ id: String) async throws {
        _ = try await request("notebooks/\(id)/delete-request", method: "DELETE")
    }

    /// Add a page the editor is already showing, under the id it picked. Safe to retry.
    func addPage(_ page: Page, notebookId: String, afterIndex: Int) async throws {
        struct Body: Encodable { var pageIds: [String]; var afterIndex: Int; var background: PageBackground }
        _ = try await request("notebooks/\(notebookId)/pages", method: "POST", json: Body(pageIds: [page.id], afterIndex: afterIndex, background: page.background))
    }

    func deletePages(notebookId: String, pageIds: [String]) async throws -> Notebook {
        struct Body: Encodable { var pageIds: [String] }
        return try decode(Notebook.self, await request("notebooks/\(notebookId)/pages/delete", method: "POST", json: Body(pageIds: pageIds)))
    }

    func reorderPages(notebookId: String, pageIds: [String]) async throws -> Notebook {
        struct Body: Encodable { var pageIds: [String] }
        return try decode(Notebook.self, await request("notebooks/\(notebookId)/pages/reorder", method: "POST", json: Body(pageIds: pageIds)))
    }

    struct PageTransfer: Decodable { var notebook: Notebook; var pages: [Page] }

    func duplicatePages(_ pageIds: [String], into notebookId: String, afterPage: Int) async throws -> PageTransfer {
        struct Body: Encodable { var pageIds: [String]; var targetNotebookId: String; var afterPage: Int }
        return try decode(PageTransfer.self, await request("pages/duplicate", method: "POST", json: Body(pageIds: pageIds, targetNotebookId: notebookId, afterPage: afterPage)))
    }

    func movePages(_ pageIds: [String], into notebookId: String, afterPage: Int) async throws -> PageTransfer {
        struct Body: Encodable { var pageIds: [String]; var targetNotebookId: String; var afterPage: Int }
        return try decode(PageTransfer.self, await request("pages/move", method: "POST", json: Body(pageIds: pageIds, targetNotebookId: notebookId, afterPage: afterPage)))
    }


    func setView(notebookId: String, pageId: String) async throws {
        struct Body: Encodable { var notebookId: String; var pageId: String }
        _ = try await request("view", method: "POST", json: Body(notebookId: notebookId, pageId: pageId))
    }

    /// strokeCount lets Claude tell an empty page from one whose ink hasn't synced.
    func uploadSnapshot(pageId: String, png: Data, textBoxes: [TextBox], strokeCount: Int) async throws {
        struct Body: Encodable { var png: String; var textBoxes: [TextBox]; var strokeCount: Int }
        _ = try await request("pages/\(pageId)/snapshot", method: "PUT", json: Body(png: png.base64EncodedString(), textBoxes: textBoxes, strokeCount: strokeCount))
    }

    func uploadDrawing(pageId: String, data: Data, strokeCount: Int) async throws {
        _ = try await request("pages/\(pageId)/drawing", method: "PUT", body: data, query: [URLQueryItem(name: "strokes", value: String(strokeCount))])
    }

    func drawing(pageId: String) async throws -> Data? {
        do { return try await request("pages/\(pageId)/drawing") } catch let e as APIError where e.status == 404 { return nil }
    }

    func importPDF(_ data: Data, title: String, folderId: String? = nil) async throws -> Notebook {
        var query = [URLQueryItem(name: "title", value: title)]
        if let folderId { query.append(URLQueryItem(name: "folderId", value: folderId)) }
        return try decode(Notebook.self, await request("notebooks/import-pdf", method: "POST", body: data, contentType: "application/pdf", query: query))
    }

    func pdf(file: String) async throws -> Data {
        try await request("pdfs/\(file)")
    }

    func claudeItems(pageId: String) async throws -> [ClaudeItem] {
        struct Out: Decodable { var items: [ClaudeItem] }
        return try decode(Out.self, await request("pages/\(pageId)/claude")).items
    }

    func doubts(pageId: String) async throws -> [Doubt] {
        struct Out: Decodable { var doubts: [Doubt] }
        return try decode(Out.self, await request("pages/\(pageId)/doubts")).doubts
    }

    func markDoubt(pageId: String, region: PageRegion) async throws -> Doubt {
        struct Body: Encodable { var region: PageRegion }
        struct Out: Decodable { var doubt: Doubt }
        return try decode(Out.self, await request("pages/\(pageId)/doubts", method: "POST", json: Body(region: region))).doubt
    }

    func revealHint(pageId: String, itemId: String) async throws -> ClaudeItem {
        struct Body: Encodable {}
        struct Out: Decodable { var item: ClaudeItem }
        return try decode(Out.self, await request("pages/\(pageId)/hints/\(itemId)/reveal", method: "POST", json: Body())).item
    }

    struct SearchHit: Decodable, Identifiable {
        var notebookId: String
        var notebookTitle: String
        var pageId: String
        var pageNumber: Int
        var box: TextBox
        var id: String { "\(pageId):\(box.x):\(box.y):\(box.text)" }
    }

    func search(_ query: String) async throws -> [SearchHit] {
        struct Out: Decodable { var results: [SearchHit] }
        return try decode(Out.self, await request("search", query: [URLQueryItem(name: "q", value: query)])).results
    }

    func undoClaude(pageId: String, count: Int? = 1) async throws {
        _ = try await request("pages/\(pageId)/claude" + (count.map { "?count=\($0)" } ?? ""), method: "DELETE")
    }

    var liveURL: URL? {
        var comps = URLComponents(url: base.appending(path: "live"), resolvingAgainstBaseURL: false)
        comps?.scheme = base.scheme == "https" ? "wss" : "ws"
        comps?.queryItems = [URLQueryItem(name: "token", value: secret)]
        return comps?.url
    }
}

/// Listens on the server websocket and reconnects forever while the app is in the foreground.
@MainActor
final class LiveConnection: ObservableObject {
    @Published private(set) var connected = false
    var onEvent: ((LiveEvent) -> Void)?
    /// Requests from Claude (open a page, confirm a delete). The library owns navigation, so it handles
    /// these whichever screen is showing, while onEvent belongs to the screen on top.
    var onCommand: ((LiveEvent) -> Void)?
    /// Library metadata must refresh even while the editor owns onEvent.
    var onLibraryEvent: ((LiveEvent) -> Void)?
    static let commands: Set<String> = ["openPage", "deleteRequest"]
    private var task: URLSessionWebSocketTask?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        connect()
    }

    func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func connect() {
        guard running else { return }
        // Not set up yet (first launch sits on the setup screen): keep checking until there are credentials.
        guard let url = API.current?.liveURL else {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.connect()
            }
            return
        }
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.task else { return }
                switch result {
                case .success(let message):
                    self.connected = true
                    if case .string(let text) = message, let event = try? JSONDecoder().decode(LiveEvent.self, from: Data(text.utf8)) {
                        self.onLibraryEvent?(event)
                        if Self.commands.contains(event.type) { self.onCommand?(event) } else { self.onEvent?(event) }
                    }
                    self.receive(on: task)
                case .failure:
                    self.connected = false
                    try? await Task.sleep(for: .seconds(2))
                    self.connect()
                }
            }
        }
    }
}
