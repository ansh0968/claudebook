import PencilKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ClaudeBookApp: App {
    @StateObject private var live = LiveConnection()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(live)
                .onAppear { live.start(); Appearance.apply(appearance) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { live.start(); Appearance.apply(appearance) } else { live.stop() }
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
                    AppearanceMenu()
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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("invertPDFs") private var invertPDFs = true
    @State private var notebook: Notebook?
    @State private var index = 0
    @State private var controller = NotebookCanvasController()
    @State private var sync = "synced"
    @State private var showClaude = true
    @State private var pencilOnly = true
    @State private var showPages = false
    @State private var addingPage = false
    @State private var testHooksDone = false

    var body: some View {
        NotebookCanvas(controller: controller, dark: colorScheme == .dark, invertPDFs: invertPDFs)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(notebook.map { "\($0.title) · \(index + 1)/\($0.pages.count)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { controller.flush(); showPages = true } label: { Image(systemName: "square.grid.2x2") }
                    Button { Task { await addPage(after: index) } } label: { Image(systemName: "doc.badge.plus") }
                        .disabled(addingPage || notebook == nil)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Image(systemName: syncIcon).foregroundStyle(sync == "offline" ? .red : .secondary)
                    AppearanceMenu()
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
                        controller.scrollTo(page: i, animated: false)
                    }
                }
            }
            .onChange(of: showClaude) { _, v in controller.showClaude = v }
            .onChange(of: scenePhase) { _, p in if p != .active { controller.flush() } }
            .task { await load() }
            .onAppear {
                controller.onSyncState = { s in sync = s }
                controller.onPageChange = { i in index = i }
                controller.onPullToAdd = { Task { await addPage(after: controller.pages.count - 1) } }
                live.onEvent = { e in
                    // (Re)connected: catch up on anything Claude did while we weren't listening.
                    if e.type == "hello" { Task { await load() }; return }
                    guard e.notebookId == notebookId else { return }
                    if e.type == "claudeLayer", let pageId = e.pageId { controller.reloadClaudeLayer(pageId: pageId) }
                    if e.type == "notebook" { Task { await load() } }
                }
            }
            .task {
                // Fallback for when the live connection is down: check for Claude's changes every few seconds.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    if !live.connected { await load() }
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

    private func load() async {
        guard let nb = try? await API.current?.notebook(notebookId) else { return }
        notebook = nb
        controller.setNotebook(nb)
        index = controller.currentIndex
        runTestHooks()
    }

    /// Hooks for the CI smoke test, which can't touch the screen.
    private func runTestHooks() {
        guard !testHooksDone else { return }
        testHooksDone = true
        let env = ProcessInfo.processInfo.environment
        if env["CLAUDEBOOK_TEST_STROKE"] == "1" { controller.addTestStroke() }
        if let y = env["CLAUDEBOOK_TEST_SCROLL"].flatMap({ Double($0) }) {
            // Scroll to a notebook y (page units), e.g. between pages 1 and 2.
            Task {
                try? await Task.sleep(for: .seconds(2))
                controller.scroll(toY: y, animated: false)
            }
        }
    }

    /// Insert a blank page after page `i` and scroll to it.
    private func addPage(after i: Int) async {
        guard !addingPage, let nb = notebook, nb.pages.indices.contains(i) else { return }
        addingPage = true
        defer { addingPage = false; controller.endPullToAdd() }
        do {
            try await API.current?.addPage(notebookId: nb.id, afterIndex: i, background: nb.pages[i].background)
        } catch {
            sync = "offline"
            return
        }
        await load()
        controller.scrollTo(page: i + 1, animated: true)
    }

    private func undoClaude(count: Int?) {
        guard let id = controller.currentPage?.id else { return }
        Task {
            try? await API.current?.undoClaude(pageId: id, count: count)
            controller.reloadClaudeLayer(pageId: id)
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match iPad"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Set on the windows directly: SwiftUI's preferredColorScheme doesn't reliably go back to "system".
    @MainActor
    static func apply(_ raw: String) {
        let style: UIUserInterfaceStyle
        switch Appearance(rawValue: raw) ?? .system {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

struct AppearanceMenu: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("invertPDFs") private var invertPDFs = true

    var body: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { a in
                    Label(a.label, systemImage: a.icon).tag(a.rawValue)
                }
            }
            Toggle("Dark PDFs in dark mode", isOn: $invertPDFs)
        } label: {
            Image(systemName: "circle.lefthalf.filled")
        }
        .onChange(of: appearance) { _, v in Appearance.apply(v) }
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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("invertPDFs") private var invertPDFs = true
    @State private var image: UIImage?

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable() } else { Color(uiColor: dark ? PaperView.darkPaper : .white) }
        }
        .aspectRatio(PageGeometry.width / PageGeometry.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .task(id: "\(page.id)-\(dark)-\(invertPDFs)") { image = await render() }
    }

    private func render() async -> UIImage {
        var pdf: CGPDFPage?
        if let ref = page.pdf { pdf = await PDFCache.page(ref) }
        let drawing = LocalDrawings.load(page.id) ?? PKDrawing()
        let size = CGSize(width: 200, height: 200 * PageGeometry.height / PageGeometry.width)
        let s = size.width / PageGeometry.width
        let style = PaperStyle(background: page.background, pdf: pdf, dark: dark, invertPDF: invertPDFs)
        var image = UIImage()
        // PencilKit picks ink colors for the current appearance, so render in the one on screen.
        UITraitCollection(userInterfaceStyle: style.dark ? .dark : .light).performAsCurrent {
            image = UIGraphicsImageRenderer(size: size).image { ctx in
                let cg = ctx.cgContext
                cg.scaleBy(x: s, y: s)
                PaperView.drawPaper(style, in: cg)
                drawing.image(from: PageGeometry.rect, scale: s * 2).draw(in: PageGeometry.rect)
                for item in page.claudeLayer { ClaudeRenderer.draw(item, dark: style.dark, in: cg) }
            }
        }
        return image
    }
}
