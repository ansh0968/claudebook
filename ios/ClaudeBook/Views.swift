import PencilKit
import SwiftUI
import UniformTypeIdentifiers

enum StudyPalette {
    static let teal = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#91CDC6") : UIColor(hex: "#246E6B") })
    static let coral = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#EBA58D") : UIColor(hex: "#AD5038") })
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#151D1F") : UIColor(hex: "#F5F1E9") })
}

struct NotebookDestination: Hashable {
    var notebookId: String
    var pageId: String? = nil
    var region: PageRegion? = nil
}

@main
struct ClaudeBookApp: App {
    @StateObject private var live = LiveConnection()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(live)
                .tint(StudyPalette.teal)
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
    @State private var path: [NotebookDestination] = []
    @State private var searchText = ""
    @State private var searchHits: [API.SearchHit] = []
    @State private var searching = false
    @State private var searchError: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your notebooks").font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 0.16, green: 0.22, blue: 0.23))
                            Text("A quiet place for your ideas and questions")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(notebooks.count) book\(notebooks.count == 1 ? "" : "s")")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search your handwriting", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Search handwritten notes")
                            .accessibilityIdentifier("library.search")
                        if searching { ProgressView().controlSize(.small) }
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        if let searchError {
                            ContentUnavailableView("Search unavailable", systemImage: "wifi.exclamationmark", description: Text(searchError))
                        } else if searchHits.isEmpty && !searching {
                            ContentUnavailableView.search(text: searchText)
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(searchHits) { hit in
                                    Button {
                                        path.append(NotebookDestination(notebookId: hit.notebookId, pageId: hit.pageId,
                                                                        region: PageRegion(x: hit.box.x, y: hit.box.y, w: hit.box.w, h: hit.box.h)))
                                    } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: "text.magnifyingglass")
                                                .font(.title3).frame(width: 38, height: 38)
                                                .foregroundStyle(StudyPalette.teal)
                                                .background(StudyPalette.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(hit.box.text).font(.body.weight(.medium)).lineLimit(2)
                                                Text("\(hit.notebookTitle) · Page \(hit.pageNumber)")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                        }
                                        .padding(14)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else if notebooks.isEmpty {
                        ContentUnavailableView("Your first notebook", systemImage: "book.closed", description: Text("Create a notebook or import a PDF to begin."))
                            .frame(maxWidth: .infinity)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)], spacing: 24) {
                            ForEach(Array(notebooks.enumerated()), id: \.element.id) { i, nb in
                                NavigationLink(value: NotebookDestination(notebookId: nb.id)) { NotebookCard(notebook: nb, tint: color(for: i)) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("notebook.\(nb.id)")
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .padding(28)
            }
            .background(StudyPalette.background)
            .navigationTitle("ClaudeBook")
            .navigationDestination(for: NotebookDestination.self) { destination in
                NotebookEditor(notebookId: destination.notebookId, initialPageId: destination.pageId, initialRegion: destination.region)
            }
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
                    Button { showImport = true } label: { Label("Import PDF", systemImage: "square.and.arrow.down") }
                        .accessibilityLabel("Import PDF")
                    Button { showNew = true } label: { Label("New notebook", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
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
            .task(id: searchText) {
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                searchError = nil
                searchHits = []
                guard !query.isEmpty else { searching = false; return }
                searching = true
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                do {
                    let results = try await API.current?.search(query) ?? []
                    guard !Task.isCancelled else { return }
                    searchHits = results
                } catch {
                    guard !Task.isCancelled else { return }
                    searchError = error.localizedDescription
                }
                searching = false
            }
            .task {
                let view = await load()
                // CI smoke test: jump straight into the open notebook.
                if ProcessInfo.processInfo.environment["CLAUDEBOOK_AUTOOPEN"] == "1", let id = view?.notebookId { path = [NotebookDestination(notebookId: id)] }
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
            path.append(NotebookDestination(notebookId: nb.id))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        do {
            let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let nb = try await API.current?.createNotebook(title: title.isEmpty ? "Untitled" : title, background: .lined) else { return }
            newTitle = ""
            await load()
            path.append(NotebookDestination(notebookId: nb.id))
        } catch { self.error = error.localizedDescription }
    }

    private func color(for index: Int) -> Color {
        let palette: [Color] = [Color(red: 0.77, green: 0.39, blue: 0.30), Color(red: 0.22, green: 0.48, blue: 0.46),
                                Color(red: 0.39, green: 0.44, blue: 0.58), Color(red: 0.64, green: 0.47, blue: 0.36)]
        return palette[index % palette.count]
    }
}

struct NotebookCard: View {
    let notebook: Notebook
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 13)
                .fill(tint.gradient)
                .aspectRatio(0.76, contentMode: .fit)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.12)).frame(width: 12).padding(.leading, 8)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "sparkle").font(.title2).foregroundStyle(.white.opacity(0.62)).padding(18)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(notebook.title).font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white).lineLimit(3).padding(18)
                }
                .shadow(color: tint.opacity(0.17), radius: 10, y: 5)
            HStack {
                Text("\(notebook.pages.count) page\(notebook.pages.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(notebook.title), \(notebook.pages.count) pages")
    }
}

struct NotebookEditor: View {
    let notebookId: String
    var initialPageId: String? = nil
    var initialRegion: PageRegion? = nil
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
    @State private var askingClaude = false
    @State private var notice: String?
    @State private var initialJumpDone = false
    @State private var loadError: String?
    @State private var markingDoubt = false

    var body: some View {
        NotebookCanvas(controller: controller, dark: colorScheme == .dark, invertPDFs: invertPDFs)
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if notebook == nil {
                    if let loadError {
                        ContentUnavailableView {
                            Label("Couldn’t open notebook", systemImage: "wifi.exclamationmark")
                        } description: { Text(loadError) } actions: {
                            Button("Try again") { Task { await load() } }.buttonStyle(.borderedProminent)
                        }
                    } else { ProgressView("Opening notebook…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
                }
            }
            .overlay(alignment: .top) {
                if askingClaude || notice != nil {
                    HStack(spacing: 12) {
                        Image(systemName: askingClaude ? "rectangle.dashed" : "bubble.left.and.bubble.right")
                            .foregroundStyle(StudyPalette.coral)
                        Text(askingClaude ? (notice ?? "Drag around a question on one page") : (notice ?? ""))
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 6)
                        Button("Dismiss") {
                            askingClaude = false; notice = nil; controller.cancelDoubtSelection()
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 22).padding(.top, 10)
                }
            }
            .navigationTitle(notebook.map { "\($0.title) · \(index + 1)/\($0.pages.count)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { controller.flush(); showPages = true } label: { Image(systemName: "square.grid.2x2") }
                        .accessibilityLabel("All pages")
                        .accessibilityIdentifier("editor.pages")
                        .disabled(notebook == nil)
                    Button { Task { await addPage(after: index) } } label: { Image(systemName: "doc.badge.plus") }
                        .disabled(addingPage || notebook == nil)
                        .accessibilityLabel("Add a page")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Image(systemName: syncIcon).foregroundStyle(sync == "offline" ? .red : .secondary)
                        .accessibilityLabel(sync == "synced" ? "All changes saved" : "Sync status: \(sync)")
                    Button {
                        askingClaude.toggle()
                        notice = nil
                        if askingClaude { controller.beginDoubtSelection() } else { controller.cancelDoubtSelection() }
                    } label: {
                        Label("Ask Claude", systemImage: askingClaude ? "xmark.circle" : "questionmark.bubble")
                    }
                    .tint(StudyPalette.coral)
                    .disabled(notebook == nil || markingDoubt)
                    .accessibilityLabel(askingClaude ? "Cancel question selection" : "Ask Claude about part of this page")
                    .accessibilityIdentifier("editor.askClaude")
                    AppearanceMenu()
                    Menu {
                        Toggle("Draw with Apple Pencil only", isOn: $pencilOnly)
                        Toggle("Show Claude's ink", isOn: $showClaude)
                        Button("Undo Claude's last mark") { undoClaude(count: 1) }
                        Button("Clear Claude's ink on this page", role: .destructive) { undoClaude(count: nil) }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Drawing options")
                }
            }
            .sheet(isPresented: $showPages) {
                if let notebook {
                    // Layer events update the controller directly; thumbnails should show those changes too.
                    PageGrid(notebook: notebookWithCurrentPages(notebook), current: index) { i in
                        showPages = false
                        controller.scrollTo(page: i, animated: false)
                    }
                }
            }
            .onChange(of: showClaude) { _, v in controller.showClaude = v }
            .onChange(of: pencilOnly) { _, v in controller.pencilOnly = v }
            .onChange(of: scenePhase) { _, p in if p != .active { controller.flush() } }
            .task { await load() }
            .onAppear {
                controller.onSyncState = { s in sync = s }
                controller.onPageChange = { i in index = i }
                controller.onPullToAdd = { Task { await addPage(after: controller.pages.count - 1) } }
                controller.onDoubtRegion = { pageId, region in
                    askingClaude = false
                    notice = "Saving question…"
                    markingDoubt = true
                    Task {
                        defer { markingDoubt = false }
                        do {
                            guard let api = API.current else { return }
                            let doubt = try await api.markDoubt(pageId: pageId, region: region)
                            controller.addDoubt(doubt)
                            notice = "Question marked. In Claude, say “check my doubts.”"
                            UIAccessibility.post(notification: .announcement, argument: notice)
                        } catch {
                            notice = "Couldn’t mark this question: \(error.localizedDescription)"
                        }
                    }
                }
                controller.onSelectionError = { notice = "Drag a larger rectangle, starting inside one page." }
                controller.onHintError = { message in notice = "Couldn’t reveal hint: \(message)" }
                live.onEvent = { e in
                    // (Re)connected: catch up on anything Claude did while we weren't listening.
                    if e.type == "hello" { Task { await load() }; return }
                    if let pageId = e.pageId, controller.pages.contains(where: { $0.id == pageId }) {
                        if e.type == "claudeLayer" { controller.reloadClaudeLayer(pageId: pageId) }
                        if e.type == "doubts" { controller.reloadDoubts(pageId: pageId) }
                    }
                    guard e.notebookId == notebookId else { return }
                    if e.type == "notebook" { Task { await load() } }
                }
            }
            .task {
                // Fallback for when the live connection is down: check for Claude's changes every few seconds.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { break }
                    if !live.connected { await load() }
                }
            }
            .onDisappear { controller.flush(); controller.cancelDoubtSelection() }
    }

    private var syncIcon: String {
        switch sync {
        case "syncing": return "arrow.triangle.2.circlepath"
        case "offline": return "exclamationmark.icloud"
        case "unsynced": return "icloud"
        default: return "checkmark.icloud"
        }
    }

    private func notebookWithCurrentPages(_ notebook: Notebook) -> Notebook {
        var snapshot = notebook
        snapshot.pages = controller.pages
        return snapshot
    }

    private func load() async {
        let nb: Notebook
        do {
            guard let api = API.current else { return }
            nb = try await api.notebook(notebookId)
            loadError = nil
        } catch { loadError = error.localizedDescription; return }
        notebook = nb
        controller.setNotebook(nb)
        index = controller.currentIndex
        if !initialJumpDone, let initialPageId, let target = nb.pages.firstIndex(where: { $0.id == initialPageId }) {
            initialJumpDone = true
            if let initialRegion {
                controller.scrollToRegion(pageIndex: target, region: initialRegion)
            } else {
                controller.scrollTo(page: target, animated: false)
            }
        }
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
    @Environment(\.dismiss) private var dismiss

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
                        .accessibilityLabel("Page \(i + 1)\(i == current ? ", current page" : "")")
                        .accessibilityIdentifier("page.\(page.id)")
                    }
                }
                .padding(20)
            }
            .navigationTitle(notebook.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .background(StudyPalette.background)
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
            if let image { Image(uiImage: image).resizable() } else { Color(uiColor: dark ? PaperView.darkPaper : PaperView.lightPaper) }
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
