import PDFKit
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ClaudeBookApp: App {
    @StateObject private var live = LiveConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(live)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { live.start() } else { live.stop() }
                }
        }
    }
}

struct RootView: View {
    @State private var configured = Credentials.isConfigured

    var body: some View {
        if configured {
            LibraryView(onSignOut: { configured = false })
        } else {
            SetupView(onDone: { configured = true })
        }
    }
}

/// First launch: where's the server and what's the secret.
struct SetupView: View {
    var onDone: () -> Void
    @State private var url = Credentials.serverURL
    @State private var secret = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://book.clarifiq.in", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Secret", text: $secret)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button(checking ? "Checking…" : "Connect") { Task { await connect() } }
                    .disabled(checking || secret.isEmpty)
            }
            .navigationTitle("Connect ClaudeBook")
        }
    }

    private func connect() async {
        checking = true
        defer { checking = false }
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)) else { error = "That URL looks off"; return }
        do {
            _ = try await API(base: base, secret: secret).notebooks()
            Credentials.serverURL = base.absoluteString
            Credentials.secret = secret
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LibraryView: View {
    var onSignOut: () -> Void
    @EnvironmentObject private var live: LiveConnection
    @State private var notebooks: [Notebook] = []
    @State private var error: String?
    @State private var newTitle = ""
    @State private var showNew = false
    @State private var showImport = false
    @State private var importing = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 24)], spacing: 24) {
                    ForEach(notebooks) { nb in
                        NavigationLink(value: nb.id) {
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(color(for: nb.id).gradient)
                                    .aspectRatio(0.72, contentMode: .fit)
                                    .overlay(alignment: .bottomLeading) {
                                        Text(nb.title).font(.headline).foregroundStyle(.white).padding(12)
                                    }
                                Text("\(nb.pages.count) page\(nb.pages.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                if let error { Text(error).foregroundStyle(.red).padding() }
            }
            .navigationTitle("ClaudeBook")
            .navigationDestination(for: String.self) { id in NotebookEditor(notebookId: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Disconnect server", role: .destructive) { Credentials.secret = ""; onSignOut() }
                    } label: {
                        Label(live.connected ? "Live" : "Offline", systemImage: live.connected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if importing { ProgressView() }
                    Button { showImport = true } label: { Label("Import PDF", systemImage: "doc.richtext") }
                    Button { showNew = true } label: { Label("New notebook", systemImage: "plus") }
                }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result { Task { await importPDF(url) } }
            }
            .alert("New notebook", isPresented: $showNew) {
                TextField("Title", text: $newTitle)
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) {}
            }
            .refreshable { await load() }
            .task {
                let view = await load()
                // CI smoke test: jump straight into the open notebook.
                if ProcessInfo.processInfo.environment["CLAUDEBOOK_AUTOOPEN"] == "1", let id = view?.notebookId { path = [id] }
            }
            .onAppear {
                live.onEvent = { e in if e.type == "notebook" { Task { await load() } } }
            }
        }
    }

    @discardableResult
    private func load() async -> ViewState? {
        do {
            let list = try await API.current?.notebooks()
            notebooks = list?.notebooks ?? []
            error = nil
            return list?.view
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func importPDF(_ url: URL) async {
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let nb = try await API.current?.importPDF(data, title: url.deletingPathExtension().lastPathComponent) else { return }
            await load()
            path.append(nb.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        guard let nb = try? await API.current?.createNotebook(title: newTitle.isEmpty ? "Untitled" : newTitle, background: .lined) else { return }
        newTitle = ""
        await load()
        path.append(nb.id)
    }

    private func color(for id: String) -> Color {
        let palette: [Color] = [.orange, .teal, .indigo, .pink, .green, .brown, .purple]
        return palette[abs(id.hashValue) % palette.count]
    }
}

struct NotebookEditor: View {
    let notebookId: String
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.scenePhase) private var scenePhase
    @State private var notebook: Notebook?
    @State private var index = 0
    @State private var controller = PageCanvasController()
    @State private var sync = "synced"
    @State private var showClaude = true
    @State private var pencilOnly = true
    @State private var showPages = false
    @State private var testStrokeDone = false

    var body: some View {
        PageCanvas(controller: controller)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(notebook.map { "\($0.title) · \(index + 1)/\($0.pages.count)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { go(index - 1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                    Button { go(index + 1) } label: { Image(systemName: "chevron.right") }.disabled(index + 1 >= (notebook?.pages.count ?? 0))
                    Button { showPages = true } label: { Image(systemName: "square.grid.2x2") }
                    Button { Task { await addPage() } } label: { Image(systemName: "doc.badge.plus") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Image(systemName: syncIcon).foregroundStyle(sync == "offline" ? .red : .secondary)
                    Button { pencilOnly.toggle(); controller.pencilOnly = pencilOnly } label: {
                        Image(systemName: pencilOnly ? "applepencil" : "hand.draw")
                    }
                    Menu {
                        Toggle("Show Claude's ink", isOn: $showClaude)
                        Button("Undo Claude's last mark") { undoClaude(count: 1) }
                        Button("Clear Claude's ink on this page", role: .destructive) { undoClaude(count: nil) }
                    } label: {
                        Image(systemName: "sparkles").foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                    }
                }
            }
            .sheet(isPresented: $showPages) {
                if let notebook {
                    PageGrid(notebook: notebook, current: index) { i in
                        showPages = false
                        go(i)
                    }
                }
            }
            .onChange(of: showClaude) { _, v in controller.showClaude = v }
            .onChange(of: scenePhase) { _, p in if p != .active { controller.flush() } }
            .task { await load() }
            .onAppear {
                controller.onSyncState = { s in sync = s }
                live.onEvent = { e in
                    guard e.notebookId == notebookId else { return }
                    if e.type == "claudeLayer", e.pageId == controller.page?.id { controller.reloadClaudeLayer() }
                    if e.type == "notebook" { Task { await load(keepPage: true) } }
                }
            }
            .onDisappear { controller.flush() }
    }

    private var syncIcon: String {
        switch sync {
        case "syncing": return "arrow.triangle.2.circlepath"
        case "offline": return "exclamationmark.icloud"
        case "unsynced": return "icloud"
        default: return "checkmark.icloud"
        }
    }

    private func load(keepPage: Bool = false) async {
        guard let nb = try? await API.current?.notebook(notebookId) else { return }
        let currentId = controller.page?.id
        notebook = nb
        if keepPage, let currentId, let i = nb.pages.firstIndex(where: { $0.id == currentId }) { index = i }
        go(min(index, nb.pages.count - 1))
        if ProcessInfo.processInfo.environment["CLAUDEBOOK_TEST_STROKE"] == "1", !testStrokeDone {
            testStrokeDone = true
            controller.addTestStroke()
        }
    }

    private func go(_ i: Int) {
        guard let nb = notebook, nb.pages.indices.contains(i) else { return }
        index = i
        let page = nb.pages[i]
        controller.show(page)
        // Tell the server this is the page on screen, so "look at my page" just works in Claude.
        Task { try? await API.current?.setView(notebookId: nb.id, pageId: page.id) }
    }

    private func addPage() async {
        guard let nb = notebook else { return }
        try? await API.current?.addPage(notebookId: nb.id, afterIndex: index, background: nb.pages[index].background)
        await load()
        go(index + 1)
    }

    private func undoClaude(count: Int?) {
        guard let id = controller.page?.id else { return }
        Task {
            try? await API.current?.undoClaude(pageId: id, count: count)
            controller.reloadClaudeLayer()
        }
    }
}

/// All pages of a notebook as thumbnails. Tap one to jump there.
struct PageGrid: View {
    let notebook: Notebook
    let current: Int
    var onPick: (Int) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 20)], spacing: 20) {
                    ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { i, page in
                        Button { onPick(i) } label: {
                            VStack(spacing: 6) {
                                PageThumbnail(page: page)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == current ? Color.accentColor : .clear, lineWidth: 3))
                                Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle(notebook.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PageThumbnail: View {
    let page: Page
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable() } else { Color.white }
        }
        .aspectRatio(PageGeometry.width / PageGeometry.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .task(id: page.id) { image = await render() }
    }

    private func render() async -> UIImage {
        var pdfPage: PDFPage?
        if let ref = page.pdf { pdfPage = await PDFCache.page(ref) }
        let drawing = LocalDrawings.load(page.id) ?? PKDrawing()
        let size = CGSize(width: 200, height: 200 * PageGeometry.height / PageGeometry.width)
        let s = size.width / PageGeometry.width
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            cg.scaleBy(x: s, y: s)
            PaperView.drawPaper(page.background, pdf: pdfPage, pixelScale: s * 2, in: cg)
            drawing.image(from: PageGeometry.rect, scale: s * 2).draw(in: PageGeometry.rect)
            for item in page.claudeLayer { ClaudeRenderer.draw(item, in: cg) }
        }
    }
}
