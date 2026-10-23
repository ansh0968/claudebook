import SwiftUI

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Label("New notebook", systemImage: "plus") }
                }
            }
            .alert("New notebook", isPresented: $showNew) {
                TextField("Title", text: $newTitle)
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) {}
            }
            .refreshable { await load() }
            .task { await load() }
            .onAppear {
                live.onEvent = { e in if e.type == "notebook" { Task { await load() } } }
            }
        }
    }

    private func load() async {
        do {
            notebooks = try await API.current?.notebooks().notebooks ?? []
            error = nil
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

    var body: some View {
        PageCanvas(controller: controller)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(notebook.map { "\($0.title) · \(index + 1)/\($0.pages.count)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { go(index - 1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                    Button { go(index + 1) } label: { Image(systemName: "chevron.right") }.disabled(index + 1 >= (notebook?.pages.count ?? 0))
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
