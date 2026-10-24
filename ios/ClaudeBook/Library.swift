import SwiftUI
import UniformTypeIdentifiers

enum LibraryRoute: Hashable {
    case notebook(NotebookDestination)
    case folder(String)
    case scratchPads
}

/// Questions the library asks: one at a time, presented from the navigation stack so they work on every screen.
enum LibraryPrompt: Identifiable {
    case newNotebook(folderId: String?)
    case newFolder(parentId: String?)
    case renameNotebook(Notebook)
    case renameFolder(Folder)
    case deleteNotebook(Notebook)
    case deleteFolder(Folder)
    case moveNotebook(Notebook)
    case moveFolder(Folder)
    case keep(Notebook)

    var id: String {
        switch self {
        case .newNotebook(let f): return "newNotebook.\(f ?? "")"
        case .newFolder(let f): return "newFolder.\(f ?? "")"
        case .renameNotebook(let n): return "renameNotebook.\(n.id)"
        case .renameFolder(let f): return "renameFolder.\(f.id)"
        case .deleteNotebook(let n): return "deleteNotebook.\(n.id)"
        case .deleteFolder(let f): return "deleteFolder.\(f.id)"
        case .moveNotebook(let n): return "moveNotebook.\(n.id)"
        case .moveFolder(let f): return "moveFolder.\(f.id)"
        case .keep(let n): return "keep.\(n.id)"
        }
    }

    var asksForText: Bool {
        switch self {
        case .newNotebook, .newFolder, .renameNotebook, .renameFolder: return true
        default: return false
        }
    }

    var isDeletion: Bool {
        switch self {
        case .deleteNotebook, .deleteFolder: return true
        default: return false
        }
    }

    var picksFolder: Bool {
        switch self {
        case .moveNotebook, .moveFolder, .keep: return true
        default: return false
        }
    }
}

/// Everything the library screens share: the notebook and folder lists, navigation, and the open prompt.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var notebooks: [Notebook] = []
    @Published var folders: [Folder] = []
    @Published var error: String?
    @Published var actionError: String?
    var prepareNotebookDeletion: ((String) async -> Void)?
    var resumeNotebookUploads: ((String) -> Void)?
    private var loadGeneration = 0
    @Published var path: [LibraryRoute] = []
    @Published var prompt: LibraryPrompt?
    @Published var promptText = ""
    @Published var creatingScratch = false
    @Published var importing = false
    @Published var claudeDeleting: Notebook?

    @discardableResult
    func load() async -> ViewState? {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            guard let list = try await API.current?.notebooks() else { return nil }
            guard generation == loadGeneration else { return list.view }
            let liveIds = Set(list.notebooks.map(\.id))
            let livePageIds = Set(list.notebooks.flatMap { $0.pages.map(\.id) })
            for removed in notebooks where !liveIds.contains(removed.id) {
                let ids = removed.pages.map(\.id).filter { !livePageIds.contains($0) }
                LocalDrawings.remove(ids)
                NotificationCenter.default.post(name: .pagesDeleted, object: nil, userInfo: ["pageIds": ids])
            }
            notebooks = list.notebooks
            path.removeAll { route in
                if case .notebook(let destination) = route { return !liveIds.contains(destination.notebookId) }
                return false
            }
            folders = list.folders ?? []
            error = nil
            // Includes requests Claude made while the app was closed.
            if let current = claudeDeleting, !notebooks.contains(where: { $0.id == current.id && $0.deleteRequestedAt != nil }) { claudeDeleting = nil }
            if claudeDeleting == nil && prompt == nil { claudeDeleting = notebooks.first { $0.deleteRequestedAt != nil } }
            return list.view
        } catch {
            guard generation == loadGeneration else { return nil }
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: Lookups

    func folder(_ id: String?) -> Folder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    func subfolders(of parentId: String?) -> [Folder] {
        folders.filter { $0.parentId == parentId }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Kept notebooks directly inside a folder (nil = top level), most recent first.
    func notebooks(in folderId: String?) -> [Notebook] {
        notebooks.filter { !$0.isScratch && $0.folderId == folderId }.sorted { $0.lastActivity > $1.lastActivity }
    }

    var scratchPads: [Notebook] {
        notebooks.filter(\.isScratch).sorted { $0.lastActivity > $1.lastActivity }
    }

    var keptCount: Int { notebooks.filter { !$0.isScratch }.count }

    /// Folders from the top level down to and including `id`.
    func ancestry(_ id: String?) -> [Folder] {
        var chain: [Folder] = []
        var current = folder(id)
        while let f = current, !chain.contains(where: { $0.id == f.id }) {
            chain.insert(f, at: 0)
            current = folder(f.parentId)
        }
        return chain
    }

    func pathName(_ id: String?) -> String {
        id == nil ? "Your notebooks" : ancestry(id).map(\.name).joined(separator: " › ")
    }

    func counts(in folderId: String) -> (notebooks: Int, folders: Int) {
        (notebooks(in: folderId).count, folders.filter { $0.parentId == folderId }.count)
    }

    struct FolderNode: Identifiable {
        var folder: Folder
        var depth: Int
        var id: String { folder.id }
    }

    /// The folder tree, depth first, for pickers. `excluding` drops that folder and everything inside it.
    func tree(excluding: String? = nil) -> [FolderNode] {
        var out: [FolderNode] = []
        func walk(_ parent: String?, _ depth: Int) {
            for f in subfolders(of: parent) where f.id != excluding {
                out.append(FolderNode(folder: f, depth: depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    // MARK: Actions

    func ask(_ prompt: LibraryPrompt) {
        actionError = nil
        switch prompt {
        case .renameNotebook(let nb): promptText = nb.title
        case .renameFolder(let f): promptText = f.name
        default: promptText = ""
        }
        self.prompt = prompt
    }

    /// The alert or confirmation dialog's main button.
    func submitPrompt(_ prompt: LibraryPrompt) {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = nil
        Task {
            switch prompt {
            case .newNotebook(let folderId): await createNotebook(title: text.isEmpty ? "Untitled" : text, in: folderId)
            case .newFolder(let parentId): if !text.isEmpty { await createFolder(text, in: parentId) }
            case .renameNotebook(let nb): if !text.isEmpty, text != nb.title { await run { try await $0.renameNotebook(nb.id, title: text) } }
            case .renameFolder(let f): if !text.isEmpty, text != f.name { await run { try await $0.renameFolder(f.id, name: text) } }
            case .deleteNotebook(let nb): await delete(nb)
            case .deleteFolder(let f): await run { try await $0.deleteFolder(f.id) }
            case .moveNotebook, .moveFolder, .keep: break
            }
        }
    }

    private func run(_ op: (API) async throws -> Void) async {
        guard let api = API.current else { return }
        actionError = nil
        do { try await op(api) } catch { self.actionError = error.localizedDescription }
        await load()
    }

    func open(_ notebookId: String) {
        path.append(.notebook(NotebookDestination(notebookId: notebookId)))
    }

    /// Commands remain owned by the library while the editor owns ink/live page updates.
    func handleCommand(_ event: LiveEvent) {
        guard let notebookId = event.notebookId else { return }
        switch event.type {
        case "openPage":
            guard let pageId = event.pageId else { return }
            if let last = path.last, case .notebook(let destination) = last, destination.notebookId == notebookId {
                NotificationCenter.default.post(name: .claudeOpenPage, object: nil, userInfo: ["notebookId": notebookId, "pageId": pageId])
            } else {
                path = [.notebook(NotebookDestination(notebookId: notebookId, pageId: pageId))]
            }
        case "deleteRequest":
            Task { await load() }
        default:
            break
        }
    }

    func cancelClaudeDelete(_ notebook: Notebook) async {
        await run { try await $0.cancelDeleteRequest(notebook.id) }
        claudeDeleting = nil
        await load()
    }

    /// One tap: a fresh grid page that cleans itself up after a week.
    func newScratchPad() async {
        guard !creatingScratch else { return }
        creatingScratch = true
        defer { creatingScratch = false }
        let title = "Scratch · " + Date().formatted(.dateTime.day().month(.abbreviated).hour().minute())
        do {
            guard let nb = try await API.current?.createNotebook(title: title, background: .grid, scratch: true) else { return }
            await load()
            open(nb.id)
        } catch { self.actionError = error.localizedDescription }
    }

    func createNotebook(title: String, in folderId: String?) async {
        do {
            guard let nb = try await API.current?.createNotebook(title: title, background: .lined, folderId: folderId) else { return }
            await load()
            open(nb.id)
        } catch { self.actionError = error.localizedDescription }
    }

    @discardableResult
    func createFolder(_ name: String, in parentId: String?) async -> Folder? {
        do {
            let folder = try await API.current?.createFolder(name: name, parentId: parentId)
            await load()
            return folder
        } catch {
            self.actionError = error.localizedDescription
            return nil
        }
    }

    func move(_ nb: Notebook, to folderId: String?) async {
        guard nb.folderId != folderId || nb.isScratch else { return }
        // Filing a scratch pad away means it's worth keeping.
        if nb.isScratch {
            guard folderId != nil else { return }
            await keep(nb, title: nb.title, in: folderId)
            return
        }
        await run { try await $0.moveNotebook(nb.id, to: folderId) }
    }

    func move(_ folder: Folder, to parentId: String?) async {
        guard folder.parentId != parentId, folder.id != parentId, !ancestry(parentId).contains(where: { $0.id == folder.id }) else { return }
        await run { try await $0.moveFolder(folder.id, to: parentId) }
    }

    func keep(_ nb: Notebook, title: String, in folderId: String?) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await run { try await $0.keepScratchPad(nb.id, title: title.isEmpty ? nb.title : title, folderId: folderId) }
    }

    func delete(_ nb: Notebook) async {
        defer { resumeNotebookUploads?(nb.id) }
        await run { api in
            await prepareNotebookDeletion?(nb.id)
            try await api.deleteNotebook(nb.id)
            // A page may have moved out since this confirmation was opened.
            // Never tombstone an id that still belongs to another notebook.
            if let remaining = try? await api.notebooks() {
                let retained = Set(remaining.notebooks.flatMap { $0.pages.map(\.id) })
                let ids = nb.pages.map(\.id).filter { !retained.contains($0) }
                LocalDrawings.remove(ids)
                NotificationCenter.default.post(name: .pagesDeleted, object: nil, userInfo: ["pageIds": ids])
            }
            path.removeAll { route in
                if case .notebook(let destination) = route { return destination.notebookId == nb.id }
                return false
            }
            if claudeDeleting?.id == nb.id { claudeDeleting = nil }
        }
    }

    func importPDF(_ url: URL, into folderId: String?) async {
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let nb = try await API.current?.importPDF(data, title: url.deletingPathExtension().lastPathComponent, folderId: folderId) else { return }
            await load()
            open(nb.id)
        } catch { self.actionError = error.localizedDescription }
    }

    /// Drag and drop payloads are "notebook:<id>" or "folder:<id>".
    func drop(_ items: [String], into folderId: String?) -> Bool {
        var handled = false
        for item in items {
            if item.hasPrefix("notebook:"), let nb = notebooks.first(where: { $0.id == String(item.dropFirst(9)) }) {
                handled = true
                Task { await move(nb, to: folderId) }
            } else if item.hasPrefix("folder:"), let f = folder(String(item.dropFirst(7))) {
                handled = true
                Task { await move(f, to: folderId) }
            }
        }
        return handled
    }

    /// CI screenshots can't tap, so they name a screen: "scratch", "folder:<name>" or "notebook:<title>".
    func testRoute(_ route: String) -> [LibraryRoute]? {
        if route == "scratch" { return [.scratchPads] }
        if route.hasPrefix("folder:"), let f = folders.first(where: { $0.name == String(route.dropFirst(7)) }) {
            return ancestry(f.id).map { .folder($0.id) }
        }
        if route.hasPrefix("notebook:"), let nb = notebooks.first(where: { $0.title.hasPrefix(String(route.dropFirst(9))) }) {
            return [.notebook(NotebookDestination(notebookId: nb.id))]
        }
        return nil
    }
}

enum LibraryTint {
    /// Same color every launch (String.hashValue changes per launch).
    static func color(for id: String) -> Color {
        let palette: [Color] = [Color(red: 0.77, green: 0.39, blue: 0.30), Color(red: 0.22, green: 0.48, blue: 0.46),
                                Color(red: 0.39, green: 0.44, blue: 0.58), Color(red: 0.64, green: 0.47, blue: 0.36),
                                Color(red: 0.49, green: 0.38, blue: 0.55), Color(red: 0.36, green: 0.52, blue: 0.36)]
        return palette[id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count]
    }
}

struct LibraryView: View {
    var onSignOut: () -> Void
    @StateObject private var model = LibraryModel()
    @EnvironmentObject private var live: LiveConnection

    var body: some View {
        NavigationStack(path: $model.path) {
            ShelfView(folderId: nil, onSignOut: onSignOut)
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .notebook(let d): NotebookEditor(notebookId: d.notebookId, initialPageId: d.pageId, initialRegion: d.region)
                    case .folder(let id): ShelfView(folderId: id)
                    case .scratchPads: ScratchPadsView()
                    }
                }
        }
        .environmentObject(model)
        .modifier(LibraryPrompts(model: model))
        // Attached above every folder screen and editor: Claude's request always asks the user first.
        .alert("Claude wants to delete “\(model.claudeDeleting?.title ?? "")”",
               isPresented: Binding(get: { model.claudeDeleting != nil }, set: { if !$0 { model.claudeDeleting = nil } }),
               presenting: model.claudeDeleting) { notebook in
            Button("Delete", role: .destructive) { Task { await model.delete(notebook) } }
            Button("Keep", role: .cancel) { Task { await model.cancelClaudeDelete(notebook) } }
        } message: { notebook in
            Text("\(notebook.pages.count) page\(notebook.pages.count == 1 ? "" : "s"), your ink and Claude's marks are removed from ClaudeBook. This can't be undone.")
        }
        .onAppear {
            live.onCommand = { event in model.handleCommand(event) }
            live.onLibraryEvent = { event in
                if ["hello", "notebook", "folders"].contains(event.type) { Task { await model.load() } }
            }
        }
        .onChange(of: model.prompt?.id) { _, value in if value == nil { Task { await model.load() } } }
        .overlay(alignment: .bottom) {
            if let message = model.actionError {
                HStack {
                    Text(message).foregroundStyle(.red)
                    Button("Dismiss") { model.actionError = nil }
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                .accessibilityIdentifier("library.actionError")
            }
        }
        .task {
            let view = await model.load()
            let env = ProcessInfo.processInfo.environment
            // CI smoke test: jump straight into the open notebook, or to a named screen.
            if env["CLAUDEBOOK_AUTOOPEN"] == "1", let id = view?.notebookId { model.path = [.notebook(NotebookDestination(notebookId: id))] }
            if let route = env["CLAUDEBOOK_TEST_ROUTE"], let path = model.testRoute(route) { model.path = path }
        }
    }
}

/// Alerts, confirmations and the folder picker, attached once above every library screen and the editor.
struct LibraryPrompts: ViewModifier {
    @ObservedObject var model: LibraryModel

    private func showing(_ test: @escaping (LibraryPrompt) -> Bool) -> Binding<Bool> {
        Binding(get: { model.prompt.map(test) ?? false }, set: { if !$0 { model.prompt = nil } })
    }

    private var textTitle: String {
        switch model.prompt {
        case .newNotebook(let f): return f == nil ? "New notebook" : "New notebook in \(model.folder(f)?.name ?? "folder")"
        case .newFolder(let f): return f == nil ? "New folder" : "New folder in \(model.folder(f)?.name ?? "folder")"
        case .renameNotebook: return "Rename notebook"
        case .renameFolder: return "Rename folder"
        default: return ""
        }
    }

    private var placeholder: String {
        if case .newFolder = model.prompt { return "Folder name" }
        return "Title"
    }

    private var confirmLabel: String {
        switch model.prompt {
        case .renameNotebook, .renameFolder: return "Save"
        default: return "Create"
        }
    }

    private var deleteLabel: String {
        if case .deleteFolder = model.prompt { return "Delete folder" }
        return "Delete"
    }

    private var deleteTitle: String {
        switch model.prompt {
        case .deleteNotebook(let nb): return "Delete “\(nb.title)”?"
        case .deleteFolder(let f): return "Delete folder “\(f.name)”?"
        default: return ""
        }
    }

    private var deleteMessage: String {
        switch model.prompt {
        case .deleteNotebook(let nb):
            return nb.isScratch ? "This scratch pad and everything on it is removed now instead of in a few days."
                : "Its pages, your ink and Claude's marks are removed from ClaudeBook. This can't be undone."
        case .deleteFolder(let f):
            return "Nothing inside is deleted. Its notebooks and folders move to \(f.parentId == nil ? "the top level" : "“\(model.folder(f.parentId)?.name ?? "")”")."
        default: return ""
        }
    }

    func body(content: Content) -> some View {
        content
            .alert(textTitle, isPresented: showing(\.asksForText), presenting: model.prompt) { prompt in
                TextField(placeholder, text: $model.promptText)
                Button(confirmLabel) { model.submitPrompt(prompt) }.accessibilityIdentifier("library.promptConfirm")
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: showing(\.isDeletion), titleVisibility: .visible, presenting: model.prompt) { prompt in
                Button(deleteLabel, role: .destructive) { model.submitPrompt(prompt) }.accessibilityIdentifier("library.confirmDelete")
            } message: { _ in
                Text(deleteMessage)
            }
            .sheet(item: Binding(get: { model.prompt?.picksFolder == true ? model.prompt : nil }, set: { if $0 == nil { model.prompt = nil } })) { prompt in
                FolderPicker(prompt: prompt).environmentObject(model)
            }
    }
}

/// One level of the library: the top level (with scratch pads and search) or a folder.
struct ShelfView: View {
    let folderId: String?
    var onSignOut: () -> Void = {}
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var searchHits: [API.SearchHit] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var dropTarget: String?
    @State private var showImport = false

    private var isRoot: Bool { folderId == nil }
    private var folder: Folder? { model.folder(folderId) }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var titleColor: Color { colorScheme == .dark ? .white : Color(red: 0.16, green: 0.22, blue: 0.23) }
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if isRoot { searchField }
                if !isRoot && folder == nil && !model.folders.isEmpty {
                    ContentUnavailableView("This folder was deleted", systemImage: "folder.badge.minus",
                                           description: Text("Its notebooks moved up a level."))
                        .frame(maxWidth: .infinity)
                } else if isRoot && !query.isEmpty {
                    searchResults
                } else {
                    if isRoot { scratchStrip }
                    foldersSection
                    notebooksSection
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .padding(28)
        }
        .background(StudyPalette.background)
        .navigationTitle(isRoot ? "ClaudeBook" : (folder?.name ?? "Folder"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { Task { await model.importPDF(url, into: folderId) } }
        }
        .refreshable { await model.load() }
        .task(id: searchText) { await search() }
        .onAppear {
            live.onEvent = { e in if e.type == "notebook" || e.type == "folders" { Task { await model.load() } } }
            Task { await model.load() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isRoot { breadcrumbs }
            Text(isRoot ? "Your notebooks" : (folder?.name ?? ""))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(titleColor)
            HStack(spacing: 6) {
                Text(summary)
                let questions = (isRoot ? model.notebooks : model.notebooks(in: folderId)).reduce(0) { $0 + $1.openDoubts }
                if questions > 0 {
                    Text("·")
                    Label("\(questions) open question\(questions == 1 ? "" : "s") for Claude", systemImage: "questionmark.bubble.fill")
                        .foregroundStyle(StudyPalette.coral)
                }
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let notebooks = isRoot ? model.keptCount : model.notebooks(in: folderId).count
        let folders = model.subfolders(of: folderId).count
        var parts = ["\(notebooks) notebook\(notebooks == 1 ? "" : "s")"]
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Tap to jump up; drop a notebook on a crumb to move it there.
    private var breadcrumbs: some View {
        let chain = model.ancestry(folderId).dropLast()
        return HStack(spacing: 4) {
            crumb(nil, name: "Your notebooks", depth: 0)
            ForEach(Array(chain.enumerated()), id: \.element.id) { i, f in
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                crumb(f.id, name: f.name, depth: i + 1)
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func crumb(_ id: String?, name: String, depth: Int) -> some View {
        let key = "crumb.\(id ?? "")"
        return Button {
            model.path = Array(model.ancestry(id).map { LibraryRoute.folder($0.id) })
        } label: {
            Label(name, systemImage: id == nil ? "books.vertical" : "folder")
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(StudyPalette.teal.opacity(dropTarget == key ? 0.22 : 0.08), in: Capsule())
        }
        .foregroundStyle(StudyPalette.teal)
        .dropDestination(for: String.self) { items, _ in model.drop(items, into: id) } isTargeted: { setTarget(key, $0) }
    }

    private func setTarget(_ key: String, _ on: Bool) {
        if on { dropTarget = key } else if dropTarget == key { dropTarget = nil }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notebooks and handwriting", text: $searchText)
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
    }

    private var titleMatches: [Notebook] {
        Array(model.notebooks.filter { $0.title.localizedCaseInsensitiveContains(query) }.sorted { $0.lastActivity > $1.lastActivity }.prefix(8))
    }

    @ViewBuilder
    private var searchResults: some View {
        let titles = titleMatches
        if titles.isEmpty && searchHits.isEmpty && !searching {
            if let searchError {
                ContentUnavailableView("Search unavailable", systemImage: "wifi.exclamationmark", description: Text(searchError))
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(titles) { nb in
                    resultRow(icon: nb.isScratch ? "scribble.variable" : "book.closed", tint: LibraryTint.color(for: nb.id), title: nb.title,
                              detail: nb.isScratch ? "Scratch pad" : model.pathName(nb.folderId)) {
                        model.open(nb.id)
                    }
                }
                ForEach(searchHits) { hit in
                    resultRow(icon: "text.magnifyingglass", tint: StudyPalette.teal, title: hit.box.text, detail: "\(hit.notebookTitle) · Page \(hit.pageNumber)") {
                        model.path.append(.notebook(NotebookDestination(notebookId: hit.notebookId, pageId: hit.pageId,
                                                                        region: PageRegion(x: hit.box.x, y: hit.box.y, w: hit.box.w, h: hit.box.h))))
                    }
                }
                if let searchError { Text(searchError).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private func resultRow(icon: String, tint: Color, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3).frame(width: 38, height: 38)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func search() async {
        searchError = nil
        searchHits = []
        guard isRoot, !query.isEmpty else { searching = false; return }
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

    // MARK: Sections

    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(titleColor)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private var scratchStrip: some View {
        let pads = model.scratchPads
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Scratch pads", detail: "Quick pages that clean themselves up after 7 days")
                Spacer()
                if !pads.isEmpty {
                    NavigationLink(value: LibraryRoute.scratchPads) {
                        HStack(spacing: 4) { Text("See all \(pads.count)"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityIdentifier("library.allScratch")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    NewScratchTile(busy: model.creatingScratch) { Task { await model.newScratchPad() } }
                        .frame(width: 150)
                        .accessibilityIdentifier("library.newScratch")
                    ForEach(pads.prefix(12)) { nb in
                        NavigationLink(value: LibraryRoute.notebook(NotebookDestination(notebookId: nb.id))) { ScratchCard(notebook: nb) }
                            .buttonStyle(.plain)
                            .frame(width: 150)
                            .modifier(NotebookActions(notebook: nb))
                            .accessibilityIdentifier("notebook.\(nb.id)")
                    }
                    if pads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Need somewhere to think?", systemImage: "lightbulb").font(.subheadline.weight(.semibold))
                            Text("Tap for a blank grid page. Keep it if it turns into something, or let it delete itself after a week.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(width: 280, alignment: .leading)
                        .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 8)
            }
            .padding(.horizontal, -28)
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        let subs = model.subfolders(of: folderId)
        if !subs.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader(isRoot ? "Folders" : "Inside \(folder?.name ?? "")")
                    Spacer()
                    Button { model.ask(.newFolder(parentId: folderId)) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                        .font(.subheadline.weight(.semibold))
                }
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(subs) { f in
                        let counts = model.counts(in: f.id)
                        NavigationLink(value: LibraryRoute.folder(f.id)) {
                            FolderTile(folder: f, notebooks: counts.notebooks, folders: counts.folders, targeted: dropTarget == "folder.\(f.id)")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("folder.\(f.id)")
                        .contextMenu {
                            Button { model.ask(.renameFolder(f)) } label: { Label("Rename", systemImage: "pencil") }
                            Button { model.ask(.moveFolder(f)) } label: { Label("Move to…", systemImage: "folder") }
                            Button(role: .destructive) { model.ask(.deleteFolder(f)) } label: { Label("Delete folder", systemImage: "trash") }
                        }
                        .draggable("folder:\(f.id)") { FolderTile(folder: f, notebooks: counts.notebooks, folders: counts.folders, targeted: false).frame(width: 160) }
                        .dropDestination(for: String.self) { items, _ in model.drop(items, into: f.id) } isTargeted: { setTarget("folder.\(f.id)", $0) }
                    }
                }
            }
        } else if isRoot && model.keptCount > 0 {
            HStack(spacing: 18) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30)).foregroundStyle(StudyPalette.teal)
                    .frame(width: 60, height: 60)
                    .background(StudyPalette.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sort notebooks by subject").font(.headline)
                    Text("Make a folder, then drag notebooks onto it or long-press one and choose Move.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("New folder") { model.ask(.newFolder(parentId: nil)) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("library.firstFolder")
            }
            .padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var notebooksSection: some View {
        let notebooks = model.notebooks(in: folderId)
        if notebooks.isEmpty {
            if isRoot && model.keptCount == 0 {
                ContentUnavailableView {
                    Label("No notebooks yet", systemImage: "book.closed")
                } description: { Text("Create a notebook or import a PDF to begin.") } actions: {
                    Button("New notebook") { model.ask(.newNotebook(folderId: nil)) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("library.emptyCreate")
                }
                .accessibilityIdentifier("library.empty")
                    .frame(maxWidth: .infinity)
            } else if !isRoot && model.subfolders(of: folderId).isEmpty {
                ContentUnavailableView {
                    Label("Nothing in here yet", systemImage: "folder")
                } description: {
                    Text("Create a notebook here, or drag one onto this folder from the library.")
                } actions: {
                    Button("New notebook") { model.ask(.newNotebook(folderId: folderId)) }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if isRoot ? (!model.folders.isEmpty || !model.scratchPads.isEmpty) : !model.subfolders(of: folderId).isEmpty {
                    sectionHeader("Notebooks")
                }
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(notebooks) { nb in
                        NavigationLink(value: LibraryRoute.notebook(NotebookDestination(notebookId: nb.id))) {
                            NotebookCard(notebook: nb, tint: LibraryTint.color(for: nb.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("notebook.\(nb.id)")
                        .modifier(NotebookActions(notebook: nb))
                    }
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isRoot {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Disconnect server", role: .destructive) { Credentials.secret = ""; onSignOut() }
                } label: {
                    Label(live.connected ? "Live" : "Offline", systemImage: live.connected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.importing { ProgressView() }
            if isRoot { AppearanceMenu() }
            Button { showImport = true } label: { Label("Import PDF", systemImage: "square.and.arrow.down") }
                .accessibilityLabel(isRoot ? "Import PDF" : "Import PDF into this folder")
            Button { Task { await model.newScratchPad() } } label: { Label("Scratch pad", systemImage: "scribble.variable") }
                .disabled(model.creatingScratch)
                .accessibilityLabel("New scratch pad")
                .accessibilityIdentifier("library.scratchButton")
            Menu {
                Button { model.ask(.newNotebook(folderId: folderId)) } label: { Label("New notebook", systemImage: "book.closed") }
                Button { model.ask(.newFolder(parentId: folderId)) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                Button { Task { await model.newScratchPad() } } label: { Label("Scratch pad", systemImage: "scribble.variable") }
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("New notebook or folder")
            .accessibilityIdentifier("library.new")
        }
    }
}

/// Long-press menu and drag for a notebook card, scratch pad or not.
struct NotebookActions: ViewModifier {
    let notebook: Notebook
    @EnvironmentObject private var model: LibraryModel

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if notebook.isScratch {
                    Button { model.ask(.keep(notebook)) } label: { Label("Keep as notebook…", systemImage: "tray.and.arrow.down") }
                    Button(role: .destructive) { model.ask(.deleteNotebook(notebook)) } label: { Label("Delete now", systemImage: "trash") }
                } else {
                    Button { model.ask(.renameNotebook(notebook)) } label: { Label("Rename", systemImage: "pencil") }
                    Button { model.ask(.moveNotebook(notebook)) } label: { Label("Move to…", systemImage: "folder") }
                    Button(role: .destructive) { model.ask(.deleteNotebook(notebook)) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .draggable("notebook:\(notebook.id)") {
                Group {
                    if notebook.isScratch { ScratchCard(notebook: notebook) } else { NotebookCard(notebook: notebook, tint: LibraryTint.color(for: notebook.id)) }
                }
                .frame(width: 150)
            }
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
                    if notebook.openDoubts > 0 {
                        Label("\(notebook.openDoubts)", systemImage: "questionmark")
                            .font(.subheadline.weight(.bold)).foregroundStyle(tint)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white, in: Capsule())
                            .padding(14)
                    } else {
                        Image(systemName: "sparkle").font(.title2).foregroundStyle(.white.opacity(0.62)).padding(18)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(notebook.title).font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white).lineLimit(3).padding(18)
                }
                .shadow(color: tint.opacity(0.17), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(notebook.pages.count) page\(notebook.pages.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
                if let edited = notebook.lastActivityDate {
                    Text("Edited \(edited, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(notebook.title), \(notebook.pages.count) pages\(notebook.openDoubts > 0 ? ", \(notebook.openDoubts) open questions" : "")")
    }
}

/// A folder with a tab and a couple of pages peeking out, tinted like the notebook covers.
struct FolderTile: View {
    let folder: Folder
    let notebooks: Int
    let folders: Int
    var targeted = false

    private var tint: Color { LibraryTint.color(for: folder.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    // Back panel and tab.
                    UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                        .fill(tint.opacity(0.78))
                        .frame(width: w * 0.42, height: h * 0.2)
                    RoundedRectangle(cornerRadius: 14)
                        .fill(tint.opacity(0.78))
                        .frame(height: h * 0.9)
                        .offset(y: h * 0.1)
                    // Pages peeking out.
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.93))
                        .frame(width: w * 0.8, height: h * 0.5)
                        .rotationEffect(.degrees(-3))
                        .offset(x: w * 0.09, y: h * 0.17)
                    RoundedRectangle(cornerRadius: 6).fill(.white)
                        .frame(width: w * 0.82, height: h * 0.5)
                        .rotationEffect(.degrees(2))
                        .offset(x: w * 0.1, y: h * 0.21)
                    // Front panel.
                    RoundedRectangle(cornerRadius: 14)
                        .fill(tint.gradient)
                        .frame(height: h * 0.66)
                        .offset(y: h * 0.34)
                        .shadow(color: .black.opacity(0.10), radius: 3, y: -1)
                    Text(folder.name)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white).lineLimit(2)
                        .frame(width: w - 36, height: h * 0.66 - 28, alignment: .bottomLeading)
                        .offset(x: 18, y: h * 0.34 + 14)
                }
            }
            .aspectRatio(1.2, contentMode: .fit)
            .shadow(color: tint.opacity(0.18), radius: 10, y: 5)
            .scaleEffect(targeted ? 1.05 : 1)
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(StudyPalette.teal, lineWidth: 3).padding(-6)
                }
            }
            .animation(.spring(duration: 0.25), value: targeted)
            Text(contents)
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.name) folder, \(contents)")
    }

    private var contents: String {
        var parts: [String] = []
        if notebooks > 0 || folders == 0 { parts.append("\(notebooks) notebook\(notebooks == 1 ? "" : "s")") }
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// Dashed "make one now" tile, shaped like a page so it lines up with the scratch pad cards.
struct NewScratchTile: View {
    var busy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(StudyPalette.teal.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .background(StudyPalette.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .aspectRatio(PageGeometry.width / PageGeometry.height, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 10) {
                            if busy { ProgressView() } else { Image(systemName: "scribble.variable").font(.system(size: 32, weight: .medium)) }
                            Text("New scratch pad").font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(StudyPalette.teal)
                        .padding(10)
                    }
                Text("One tap, no name").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("New scratch pad")
    }
}

/// A scratch pad shows its first page, so you can tell them apart, plus how long it has left.
struct ScratchCard: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let page = notebook.pages.first { PageThumbnail(page: page) }
            }
            .overlay(alignment: .bottomLeading) { ExpiryBadge(date: notebook.expiryDate).padding(7) }
            VStack(alignment: .leading, spacing: 1) {
                Text(notebook.title.replacingOccurrences(of: "Scratch · ", with: ""))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if let edited = notebook.lastActivityDate {
                    Text("Edited \(edited, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(notebook.title), scratch pad, \(ExpiryBadge.text(notebook.expiryDate)) before it deletes itself")
    }
}

struct ExpiryBadge: View {
    let date: Date?

    static func text(_ date: Date?) -> String {
        guard let date else { return "Temporary" }
        let hours = date.timeIntervalSinceNow / 3600
        if hours < 1 { return "Deleting soon" }
        if hours < 24 { return "\(Int(hours.rounded(.up)))h left" }
        let days = Int((hours / 24).rounded(.up))
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    private var urgent: Bool { (date?.timeIntervalSinceNow ?? .infinity) < 24 * 3600 }

    var body: some View {
        Label(Self.text(date), systemImage: "timer")
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(urgent ? AnyShapeStyle(StudyPalette.coral) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
    }
}

/// Every scratch pad, newest first.
struct ScratchPadsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scratch pads")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 0.16, green: 0.22, blue: 0.23))
                    Text("Each one deletes itself 7 days after you last write on it. Keep the ones worth saving and they become normal notebooks.")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22)], alignment: .leading, spacing: 26) {
                    NewScratchTile(busy: model.creatingScratch) { Task { await model.newScratchPad() } }
                    ForEach(model.scratchPads) { nb in
                        NavigationLink(value: LibraryRoute.notebook(NotebookDestination(notebookId: nb.id))) { ScratchCard(notebook: nb) }
                            .buttonStyle(.plain)
                            .modifier(NotebookActions(notebook: nb))
                            .accessibilityIdentifier("notebook.\(nb.id)")
                    }
                }
                if model.scratchPads.isEmpty {
                    Text("No scratch pads right now. Tap the tile to start one.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .padding(28)
        }
        .background(StudyPalette.background)
        .navigationTitle("Scratch pads")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .onAppear {
            live.onEvent = { e in if e.type == "notebook" || e.type == "folders" { Task { await model.load() } } }
            Task { await model.load() }
        }
    }
}

/// Choose where a notebook or folder goes, or name and file a scratch pad you're keeping.
struct FolderPicker: View {
    let prompt: LibraryPrompt
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var name = ""
    @State private var newFolderName = ""
    @State private var addingFolder = false
    @State private var started = false
    @FocusState private var newFolderFocused: Bool

    private var title: String {
        switch prompt {
        case .moveNotebook(let nb): return "Move “\(nb.title)”"
        case .moveFolder(let f): return "Move “\(f.name)”"
        case .keep: return "Keep scratch pad"
        default: return ""
        }
    }

    private var current: String? {
        switch prompt {
        case .moveNotebook(let nb): return nb.folderId
        case .moveFolder(let f): return f.parentId
        default: return nil
        }
    }

    private var excluded: String? {
        if case .moveFolder(let f) = prompt { return f.id }
        return nil
    }

    private var keeping: Notebook? {
        if case .keep(let nb) = prompt { return nb }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                if keeping != nil {
                    Section {
                        TextField("Notebook name", text: $name)
                            .font(.title3.weight(.medium))
                            .accessibilityIdentifier("picker.name")
                    } header: {
                        Text("Name")
                    } footer: {
                        Text("Kept scratch pads become normal notebooks and are never deleted automatically.")
                    }
                }
                Section {
                    row(nil, name: "Your notebooks", depth: 0)
                    ForEach(model.tree(excluding: excluded)) { node in
                        row(node.folder.id, name: node.folder.name, depth: node.depth + 1)
                    }
                    if addingFolder {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus").foregroundStyle(StudyPalette.teal)
                            TextField("New folder in \(selection.flatMap { model.folder($0)?.name } ?? "Your notebooks")", text: $newFolderName)
                                .focused($newFolderFocused)
                                .onSubmit { Task { await addFolder() } }
                            Button("Add") { Task { await addFolder() } }
                                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        Button {
                            addingFolder = true
                            newFolderFocused = true
                        } label: {
                            Label("New folder…", systemImage: "folder.badge.plus")
                        }
                    }
                } header: {
                    Text(keeping != nil ? "Save in" : "Folder")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(keeping != nil ? "Keep" : "Move") { confirm() }
                        .fontWeight(.semibold)
                        .disabled(keeping == nil && selection == current)
                        .accessibilityIdentifier("picker.confirm")
                }
            }
            .onAppear {
                guard !started else { return }
                started = true
                selection = current
                if let keeping { name = keeping.title }
            }
        }
    }

    private func row(_ id: String?, name: String, depth: Int) -> some View {
        Button { selection = id } label: {
            HStack(spacing: 12) {
                Image(systemName: id == nil ? "books.vertical.fill" : "folder.fill")
                    .foregroundStyle(id.map { LibraryTint.color(for: $0) } ?? StudyPalette.teal)
                    .frame(width: 24)
                Text(name).foregroundStyle(Color.primary)
                if id != nil && id == current {
                    Text("Current").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(StudyPalette.teal)
                }
            }
            .padding(.leading, CGFloat(depth) * 22)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id.map { "picker.folder.\($0)" } ?? "picker.topLevel")
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }

    private func addFolder() async {
        let folderName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty else { return }
        if let folder = await model.createFolder(folderName, in: selection) {
            selection = folder.id
            newFolderName = ""
            addingFolder = false
        }
    }

    private func confirm() {
        let target = selection
        let name = name
        let prompt = prompt
        dismiss()
        Task {
            switch prompt {
            case .moveNotebook(let nb): await model.move(nb, to: target)
            case .moveFolder(let f): await model.move(f, to: target)
            case .keep(let nb): await model.keep(nb, title: name, in: target)
            default: break
            }
        }
    }
}
