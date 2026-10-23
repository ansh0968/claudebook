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

    func createNotebook(title: String, background: PageBackground) async throws -> Notebook {
        struct Body: Encodable { var title: String; var pages: Int; var background: PageBackground }
        return try decode(Notebook.self, await request("notebooks", method: "POST", json: Body(title: title, pages: 1, background: background)))
    }

    func addPage(notebookId: String, afterIndex: Int, background: PageBackground) async throws {
        struct Body: Encodable { var count: Int; var afterIndex: Int; var background: PageBackground }
        _ = try await request("notebooks/\(notebookId)/pages", method: "POST", json: Body(count: 1, afterIndex: afterIndex, background: background))
    }

    func setView(notebookId: String, pageId: String) async throws {
        struct Body: Encodable { var notebookId: String; var pageId: String }
        _ = try await request("view", method: "POST", json: Body(notebookId: notebookId, pageId: pageId))
    }

    func uploadSnapshot(pageId: String, png: Data, textBoxes: [TextBox]) async throws {
        struct Body: Encodable { var png: String; var textBoxes: [TextBox] }
        _ = try await request("pages/\(pageId)/snapshot", method: "PUT", json: Body(png: png.base64EncodedString(), textBoxes: textBoxes))
    }

    func uploadDrawing(pageId: String, data: Data) async throws {
        _ = try await request("pages/\(pageId)/drawing", method: "PUT", body: data)
    }

    func drawing(pageId: String) async throws -> Data? {
        do { return try await request("pages/\(pageId)/drawing") } catch let e as APIError where e.status == 404 { return nil }
    }

    func importPDF(_ data: Data, title: String) async throws -> Notebook {
        try decode(Notebook.self, await request("notebooks/import-pdf", method: "POST", body: data, contentType: "application/pdf", query: [URLQueryItem(name: "title", value: title)]))
    }

    func pdf(file: String) async throws -> Data {
        try await request("pdfs/\(file)")
    }

    func claudeItems(pageId: String) async throws -> [ClaudeItem] {
        struct Out: Decodable { var items: [ClaudeItem] }
        return try decode(Out.self, await request("pages/\(pageId)/claude")).items
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
                        self.onEvent?(event)
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
