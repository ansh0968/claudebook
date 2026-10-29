import PencilKit
import SwiftUI
import UniformTypeIdentifiers

enum StudyPalette {
    static let teal = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#91CDC6") : UIColor(hex: "#246E6B") })
    static let coral = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#EBA58D") : UIColor(hex: "#AD5038") })
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#151D1F") : UIColor(hex: "#F5F1E9") })
}

extension Notification.Name {
    /// Claude asked to flip to a page in the notebook that's already open. userInfo: notebookId, pageId.
    static let claudeOpenPage = Notification.Name("claudeOpenPage")
    static let pagesDeleted = Notification.Name("pagesDeleted")
    static let localDrawingChanged = Notification.Name("localDrawingChanged")
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
                // Applied here, not in the menu: menu content isn't kept alive, so its onChange may never run.
                .onChange(of: appearance) { _, v in Appearance.apply(v) }
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
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image("Clawd")
                        .resizable()
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    Text("ClaudeBook")
                        .font(.system(size: 34, weight: .semibold, design: .serif))
                    Text("Write on paper, and Claude can see it and write back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("https://book.clarifiq.in", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    SecureField("Secret", text: $secret)
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onSubmit { Task { await connect() } }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(StudyPalette.coral)
                    }
                }
                Button { Task { await connect() } } label: {
                    Text(checking ? "Checking…" : "Connect")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StudyPalette.teal)
                .disabled(checking || secret.isEmpty)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
        }
        .background(StudyPalette.background.ignoresSafeArea())
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

struct NotebookEditor: View {
    let notebookId: String
    var initialPageId: String? = nil
    var initialRegion: PageRegion? = nil
    @EnvironmentObject private var live: LiveConnection
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
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
    @State private var showPaperPicker = false
    @State private var addingPage = false
    /// Bumped whenever the editor adds a page locally, so a notebook fetched before that can't remove it again.
    @State private var localPageEdits = 0
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
                if let notebook, notebook.pages.isEmpty {
                    ContentUnavailableView {
                        Label("No pages", systemImage: "doc")
                    } description: { Text("Add a page to start writing in this notebook.") } actions: {
                        Button("Add a page") { Task { await addPage(after: -1) } }
                            .buttonStyle(.borderedProminent).disabled(addingPage)
                            .accessibilityIdentifier("editor.emptyAdd")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudyPalette.background)
                } else if notebook == nil {
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
            .navigationTitle(notebook.map { $0.pages.isEmpty ? $0.title : "\($0.title) · \(index + 1)/\($0.pages.count)" } ?? "")
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
                        .accessibilityIdentifier("editor.addPage")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let notebook, notebook.isScratch {
                        // Scratch pads delete themselves after a week; one tap files this one as a real notebook.
                        Button { controller.flush(); library.ask(.keep(notebook)) } label: {
                            // Toolbars drop a Label's title; spell it out so "Keep" can't be missed.
                            HStack(spacing: 5) {
                                Image(systemName: "tray.and.arrow.down")
                                Text("Keep")
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(StudyPalette.teal)
                        .accessibilityLabel("Keep this scratch pad, \(ExpiryBadge.text(notebook.expiryDate)) before it deletes itself")
                        .accessibilityIdentifier("editor.keep")
                    }
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
                    .disabled(notebook?.pages.isEmpty != false || markingDoubt)
                    .accessibilityLabel(askingClaude ? "Cancel question selection" : "Ask Claude about part of this page")
                    .accessibilityIdentifier("editor.askClaude")
                    Menu {
                        if let notebook {
                            Section("Notebook") {
                                Button { controller.flush(); library.ask(.renameNotebook(notebook)) } label: { Label("Rename notebook", systemImage: "pencil") }
                                    .accessibilityIdentifier("editor.renameNotebook")
                                Button(role: .destructive) { library.ask(.deleteNotebook(notebook)) } label: { Label("Delete notebook", systemImage: "trash") }
                                    .accessibilityIdentifier("editor.deleteNotebook")
                            }
                        }
                        Section {
                            Toggle(isOn: $pencilOnly) { Label("Draw with Apple Pencil only", systemImage: "applepencil") }
                        }
                        Section("Claude's ink") {
                            Toggle(isOn: $showClaude) { Label("Show Claude's ink", systemImage: "eye") }
                            Button { undoClaude(count: 1) } label: { Label("Undo Claude's last mark", systemImage: "arrow.uturn.backward") }
                            Button(role: .destructive) { undoClaude(count: nil) } label: { Label("Clear Claude's ink on this page", systemImage: "trash") }
                        }
                        Button("Page type") { controller.flush(); showPaperPicker = true }.disabled(controller.currentPage == nil).accessibilityIdentifier("editor.pageType")
                        AppearanceMenu.Options()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Notebook options")
                }
            }
            .sheet(isPresented: $showPaperPicker) {
                if let notebook, let page = controller.currentPage { PaperPicker(notebook: notebook, page: page) { await load() } }
            }
            .sheet(isPresented: $showPages) {
                if let notebook {
                    // Layer events update the controller directly; thumbnails should show those changes too.
                    PageGrid(notebook: notebookWithCurrentPages(notebook), currentPageId: controller.currentPage?.id,
                             beforeMutation: { discarding in
                                 if discarding { await controller.pauseUploads() }
                                 else { try await controller.flushAndWait() }
                             }, onChanged: { updated in
                                 applyNotebook(updated)
                                 controller.flush()
                                 Task { await library.load() }
                             }, onFailure: { controller.flush() }) { pageId in
                        showPages = false
                        if let i = controller.pages.firstIndex(where: { $0.id == pageId }) { controller.scrollTo(page: i, animated: false) }
                    }
                }
            }
            .onChange(of: showClaude) { _, v in controller.showClaude = v }
            .onChange(of: pencilOnly) { _, v in controller.pencilOnly = v }
            .onChange(of: scenePhase) { _, p in if p != .active { controller.flush() } }
            .task { await load() }
            .onAppear {
                library.prepareNotebookDeletion = { id in if id == notebookId { await controller.pauseUploads() } }
                library.resumeNotebookUploads = { id in if id == notebookId { controller.flush() } }
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
            .onReceive(NotificationCenter.default.publisher(for: .claudeOpenPage)) { note in
                guard note.userInfo?["notebookId"] as? String == notebookId, let pageId = note.userInfo?["pageId"] as? String else { return }
                Task {
                    // A page Claude just added may not be loaded yet.
                    if !controller.pages.contains(where: { $0.id == pageId }) { await load() }
                    if let i = controller.pages.firstIndex(where: { $0.id == pageId }) { controller.scrollTo(page: i, animated: true) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pagesDeleted)) { note in
                guard let ids = note.userInfo?["pageIds"] as? [String] else { return }
                controller.discardPages(ids)
            }
            .onDisappear {
                controller.flush(); controller.cancelDoubtSelection()
                library.prepareNotebookDeletion = nil
                library.resumeNotebookUploads = nil
            }
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
        let edits = localPageEdits
        do {
            guard let api = API.current else { return }
            nb = try await api.notebook(notebookId)
            // A page was added while this was in flight; the reload after that add brings the fresh copy.
            guard edits == localPageEdits, !addingPage else { return }
            loadError = nil
        } catch {
            if let apiError = error as? APIError, apiError.status == 404 {
                let ids = controller.pages.map(\.id)
                controller.discardPages(ids)
                notebook = nil
                dismiss()
                Task { await library.load() }
            } else { notice = error.localizedDescription; loadError = error.localizedDescription }
            return
        }
        applyNotebook(nb)
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

    private func applyNotebook(_ updated: Notebook) {
        let opening = controller.notebookId != updated.id
        let oldIndex = index
        notebook = updated
        controller.setNotebook(updated)
        index = controller.currentIndex
        // Once open, the controller keeps whatever is on screen in place when pages come or go.
        // Snapping to the top of the current page here is what made the view jump after adding a page.
        if opening, !updated.pages.isEmpty {
            controller.scrollTo(page: min(oldIndex, updated.pages.count - 1), animated: false)
        }
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

    /// Insert a blank page after page `i` and glide to it. The page shows up straight away and the server
    /// is told in the background; if it says no, the page is taken back out.
    private func addPage(after i: Int) async {
        guard !addingPage, var nb = notebook else { return }
        let after = nb.pages.isEmpty ? -1 : min(max(-1, i), nb.pages.count - 1)
        let page = Page.blank(background: nb.pages.isEmpty ? .lined : nb.pages[max(0, after)].background,
                              paper: nb.pages.isEmpty ? nil : nb.pages[max(0, after)].paper)
        addingPage = true
        localPageEdits += 1
        nb.pages.insert(page, at: after + 1)
        applyNotebook(nb)
        controller.endPullToAdd()
        controller.reveal(pageId: page.id)
        do {
            guard let api = API.current else { throw URLError(.notConnectedToInternet) }
            try await api.addPage(page, notebookId: nb.id, afterIndex: after)
        } catch {
            notice = "Couldn’t add a page: \(error.localizedDescription)"
            if var current = notebook {
                current.pages.removeAll { $0.id == page.id }
                applyNotebook(current)
            }
            // If the server did get it after all, the reload below brings it (and any ink) back.
            PendingUploads.all.remove(page.id)
        }
        addingPage = false
        await load()
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
    var body: some View {
        Menu { Options() } label: { Image(systemName: "circle.lefthalf.filled") }
            .accessibilityLabel("Appearance")
    }

    /// The appearance choices, for use inside any menu.
    struct Options: View {
        @AppStorage("appearance") private var appearance = Appearance.system.rawValue
        @AppStorage("invertPDFs") private var invertPDFs = true

        var body: some View {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in
                        Label(a.label, systemImage: a.icon).tag(a.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Toggle(isOn: $invertPDFs) { Label("Dark PDFs in dark mode", systemImage: "doc.text") }
            }
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
        .task(id: "\(page.id)-\(page.snapshotVersion)-\(page.background.rawValue)-\(page.paper?.rawValue ?? "legacy")-\(dark)-\(invertPDFs)") { image = await render() }
        .onReceive(NotificationCenter.default.publisher(for: .localDrawingChanged)) { note in
            if note.userInfo?["pageId"] as? String == page.id { Task { image = await render() } }
        }
    }

    private func render() async -> UIImage {
        for file in Set(page.claudeLayer.filter { $0.type == "image" }.compactMap(\.file)) {
            _ = await ImageCache.load(file)
        }
        var pdf: CGPDFPage?
        if let ref = page.pdf { pdf = await PDFCache.page(ref) }
        let drawing = LocalDrawings.load(page.id) ?? PKDrawing()
        let size = CGSize(width: 200, height: 200 * PageGeometry.height / PageGeometry.width)
        let s = size.width / PageGeometry.width
        let style = PaperStyle(background: page.background, paper: page.paper, pdf: pdf, dark: dark, invertPDF: invertPDFs)
        var image = UIImage()
        // PencilKit picks ink colors for the current appearance, so render in the one on screen.
        UITraitCollection(userInterfaceStyle: page.usesDarkInkPalette(appDark: dark) ? .dark : .light).performAsCurrent {
            image = UIGraphicsImageRenderer(size: size).image { ctx in
                let cg = ctx.cgContext
                cg.scaleBy(x: s, y: s)
                PaperView.drawPaper(style, in: cg)
                drawing.image(from: PageGeometry.rect, scale: s * 2).draw(in: PageGeometry.rect)
                for item in page.claudeLayer { ClaudeRenderer.draw(item, dark: page.usesDarkInkPalette(appDark: dark), in: cg) }
            }
        }
        return image
    }
}
