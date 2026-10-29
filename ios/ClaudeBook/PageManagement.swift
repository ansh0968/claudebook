import SwiftUI

/// Page operations use stable page ids; positions are only insertion counts for the API.
struct PageGrid: View {
    @State private var notebook: Notebook
    let latestNotebook: Notebook
    let currentPageId: String?
    var beforeMutation: (_ discardingInk: Bool) async throws -> Void
    var onChanged: (Notebook) -> Void
    var onFailure: () -> Void
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var deleting: [String] = []
    @State private var moving: Page?

    init(notebook: Notebook, currentPageId: String?, beforeMutation: @escaping (Bool) async throws -> Void,
         onChanged: @escaping (Notebook) -> Void, onFailure: @escaping () -> Void, onPick: @escaping (String) -> Void) {
        _notebook = State(initialValue: notebook)
        latestNotebook = notebook
        self.currentPageId = currentPageId
        self.beforeMutation = beforeMutation
        self.onChanged = onChanged
        self.onFailure = onFailure
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("pages.error")
                }
                if notebook.pages.isEmpty {
                    ContentUnavailableView("No pages", systemImage: "doc", description: Text("Add a page to start writing."))
                }
                ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: 14) {
                        Button { onPick(page.id) } label: {
                            HStack(spacing: 14) {
                                PageThumbnail(page: page).frame(width: 64, height: 90)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Page \(index + 1)").font(.headline)
                                    if page.id == currentPageId { Text("Current page").font(.caption).foregroundStyle(.secondary) }
                                    if page.pdf != nil { Label("PDF", systemImage: "doc.richtext").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(index + 1)\(page.id == currentPageId ? ", current page" : "")")
                        .accessibilityIdentifier("page.\(page.id)")
                        Menu { actions(page, index: index) } label: { Image(systemName: "ellipsis.circle").font(.title3).padding(8) }
                            // Borderless keeps the menu its own tap target instead of the whole list row.
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Actions for page \(index + 1)")
                            .accessibilityIdentifier("pages.actions.\(page.id)")
                    }
                    .contextMenu { actions(page, index: index) }
                }
                .onDelete { indexes in deleting = indexes.map { notebook.pages[$0].id } }
                .onMove { source, destination in
                    var reordered = notebook.pages
                    reordered.move(fromOffsets: source, toOffset: destination)
                    mutate { api in try await api.reorderPages(notebookId: notebook.id, pageIds: reordered.map(\.id)) }
                }
                Button { insert(at: notebook.pages.count) } label: { Label("Add a page", systemImage: "doc.badge.plus") }
                    .accessibilityIdentifier("pages.add")
            }
            .disabled(busy)
            .navigationTitle("Pages · \(notebook.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton().accessibilityIdentifier("pages.edit").disabled(busy || notebook.pages.isEmpty) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) }
                if busy { ToolbarItem(placement: .status) { ProgressView("Saving…") } }
            }
            .alert("Delete \(deleting.count == 1 ? "page" : "\(deleting.count) pages")?",
                   isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                   presenting: deleting) { ids in
                Button("Delete", role: .destructive) {
                    mutate(discardingInk: true) { api in
                        let updated = try await api.deletePages(notebookId: notebook.id, pageIds: ids)
                        LocalDrawings.remove(ids)
                        return updated
                    }
                }
                .accessibilityIdentifier("pages.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("This removes the selected pages, their handwriting and Claude’s marks. This can’t be undone.") }
            .sheet(item: $moving) { page in
                PageMovePicker(sourceNotebookId: notebook.id, pageId: page.id) { target in
                    moving = nil
                    mutate { api in
                        _ = try await api.movePages([page.id], into: target.id, afterPage: target.pages.count)
                        return try await api.notebook(notebook.id)
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .onChange(of: latestNotebook) { _, updated in notebook = updated }
    }

    @ViewBuilder
    private func actions(_ page: Page, index: Int) -> some View {
        Button { insert(at: index) } label: { Label("Insert page before", systemImage: "doc.badge.plus") }
        Button { insert(at: index + 1) } label: { Label("Insert page after", systemImage: "doc.badge.plus") }
        Button {
            mutate { api in try await api.duplicatePages([page.id], into: notebook.id, afterPage: index + 1).notebook }
        } label: { Label("Duplicate page", systemImage: "plus.square.on.square") }
        .accessibilityIdentifier("pages.duplicate.\(page.id)")
        Button { moving = page } label: { Label("Move to notebook…", systemImage: "book.closed") }
        if index > 0 {
            Button { move(page.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                .accessibilityIdentifier("pages.up.\(page.id)")
        }
        if index + 1 < notebook.pages.count {
            Button { move(page.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                .accessibilityIdentifier("pages.down.\(page.id)")
        }
        Button(role: .destructive) { deleting = [page.id] } label: { Label("Delete page", systemImage: "trash") }
            .accessibilityIdentifier("pages.delete.\(page.id)")
    }

    private func insert(at count: Int) {
        let background = notebook.pages.first?.background ?? .lined
        mutate { api in
            try await api.addPage(.blank(background: background), notebookId: notebook.id, afterIndex: count - 1)
            return try await api.notebook(notebook.id)
        }
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = notebook.pages.firstIndex(where: { $0.id == id }) else { return }
        var ids = notebook.pages.map(\.id)
        ids.swapAt(index, index + offset)
        mutate { api in try await api.reorderPages(notebookId: notebook.id, pageIds: ids) }
    }

    private func mutate(discardingInk: Bool = false, _ operation: @escaping (API) async throws -> Notebook) {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let api = API.current else { return }
                try await beforeMutation(discardingInk)
                let updated = try await operation(api)
                notebook = updated
                onChanged(updated)
            } catch {
                self.error = error.localizedDescription
                onFailure()
            }
        }
    }
}

private struct PageMovePicker: View {
    let sourceNotebookId: String
    let pageId: String
    var onPick: (Notebook) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notebooks: [Notebook] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if loaded && notebooks.isEmpty {
                    ContentUnavailableView("No other notebooks", systemImage: "book.closed", description: Text("Create another notebook in the library, then move this page into it."))
                }
                ForEach(notebooks) { notebook in
                    Button { onPick(notebook) } label: {
                        VStack(alignment: .leading) {
                            Text(notebook.title)
                            Text("\(notebook.pages.count) pages").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("pages.target.\(notebook.id)")
                }
            }
            .navigationTitle("Move page to…")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do {
                    notebooks = try await API.current?.notebooks().notebooks.filter { $0.id != sourceNotebookId }.sorted { $0.lastActivity > $1.lastActivity } ?? []
                    loaded = true
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
