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
    @State private var moving: [String]?
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive

    private var selecting: Bool { editMode.isEditing }
    /// The selection in page order, which the API and the confirmation count rely on.
    private var selectedIds: [String] { notebook.pages.map(\.id).filter { selection.contains($0) } }

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
            List(selection: $selection) {
                if let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("pages.error")
                }
                if notebook.pages.isEmpty {
                    ContentUnavailableView("No pages", systemImage: "doc", description: Text("Add a page to start writing."))
                }
                ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: 14) {
                        if selecting {
                            // While selecting, the whole row toggles selection instead of opening the page.
                            row(page, index: index)
                                .accessibilityIdentifier("pages.select.\(page.id)")
                        } else {
                            Button { onPick(page.id) } label: { row(page, index: index) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Page \(index + 1)\(page.id == currentPageId ? ", current page" : "")")
                                .accessibilityIdentifier("page.\(page.id)")
                            Menu { actions(page, index: index) } label: { Image(systemName: "ellipsis.circle").font(.title3).padding(8) }
                                // Borderless keeps the menu its own tap target instead of the whole list row.
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Actions for page \(index + 1)")
                                .accessibilityIdentifier("pages.actions.\(page.id)")
                        }
                    }
                    .tag(page.id)
                    // Selecting uses checkmarks only; the red delete badges would be a second, competing control.
                    .deleteDisabled(selecting)
                    .listRowBackground(selection.contains(page.id) ? Theme.accentSoft : Theme.surface)
                    .contextMenu { if !selecting { actions(page, index: index) } }
                }
                .onDelete { indexes in deleting = indexes.map { notebook.pages[$0].id } }
                .onMove { source, destination in
                    var reordered = notebook.pages
                    reordered.move(fromOffsets: source, toOffset: destination)
                    mutate { api in try await api.reorderPages(notebookId: notebook.id, pageIds: reordered.map(\.id)) }
                }
                if !selecting {
                    Button { insert(at: notebook.pages.count) } label: { Label("Add a page", systemImage: "doc.badge.plus") }
                        .accessibilityIdentifier("pages.add")
                        .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, $editMode)
            .disabled(busy)
            .navigationTitle(selecting ? (selection.isEmpty ? "Select pages" : "\(selection.count) selected") : "Pages · \(notebook.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Cancel" : "Select") { setSelecting(!selecting) }
                        .accessibilityIdentifier("pages.edit")
                        .disabled(busy || notebook.pages.isEmpty)
                }
                if selecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selection.count == notebook.pages.count ? "Deselect all" : "Select all") {
                            withAnimation(Theme.Motion.snappy) {
                                selection = selection.count == notebook.pages.count ? [] : Set(notebook.pages.map(\.id))
                            }
                        }
                        .accessibilityIdentifier("pages.selectAll")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) }
                }
                if busy {
                    ToolbarItem(placement: .status) {
                        HStack(spacing: 8) { ClaudeSpinner(size: 16); Text("Saving…").font(.subheadline) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(Theme.Motion.pop, value: selecting)
            .alert("Delete \(deleting.count == 1 ? "page" : "\(deleting.count) pages")?",
                   isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                   presenting: deleting) { ids in
                Button("Delete", role: .destructive) {
                    mutate(discardingInk: true, endSelection: true) { api in
                        let updated = try await api.deletePages(notebookId: notebook.id, pageIds: ids)
                        LocalDrawings.remove(ids)
                        return updated
                    }
                }
                .accessibilityIdentifier("pages.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("This removes the selected pages, their handwriting and Claude’s marks. This can’t be undone.") }
            .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
                if let ids = moving {
                    PageMovePicker(sourceNotebookId: notebook.id, count: ids.count) { target in
                        moving = nil
                        mutate(endSelection: true) { api in
                            _ = try await api.movePages(ids, into: target.id, afterPage: target.pages.count)
                            return try await api.notebook(notebook.id)
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .onAppear { testSelection() }
        .onChange(of: latestNotebook) { _, updated in notebook = updated }
    }

    private func row(_ page: Page, index: Int) -> some View {
        HStack(spacing: 16) {
            PageThumbnail(page: page).frame(width: 70, height: 99)
            VStack(alignment: .leading, spacing: 5) {
                Text("Page \(index + 1)").font(Theme.rounded(.headline, weight: .semibold)).foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    if page.id == currentPageId {
                        Text("Current page")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                    if page.pdf != nil { Label("PDF", systemImage: "doc.richtext").font(.caption).foregroundStyle(Theme.secondaryInk) }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Bulk actions for the selected pages: one delete for any number of them.
    private var selectionBar: some View {
        let count = selection.count
        return HStack(spacing: 12) {
            Text(count == 0 ? "Tap pages to select them" : "\(count) page\(count == 1 ? "" : "s")")
                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryInk)
                .contentTransition(.numericText())
            Spacer()
            Button {
                let ids = selectedIds
                let after = (notebook.pages.lastIndex { selection.contains($0.id) } ?? notebook.pages.count - 1) + 1
                mutate(endSelection: true) { api in try await api.duplicatePages(ids, into: notebook.id, afterPage: after).notebook }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("pages.duplicateSelected")
            Button { moving = selectedIds } label: { Label("Move", systemImage: "book.closed") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pages.moveSelected")
            Button(role: .destructive) { deleting = selectedIds } label: {
                Label(count > 1 ? "Delete \(count)" : "Delete", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .accessibilityIdentifier("pages.deleteSelected")
        }
        .disabled(count == 0 || busy)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .themedCard(radius: 20)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// CI can't tap, so it can ask for the grid to open already selecting two pages.
    private func testSelection() {
        guard ProcessInfo.processInfo.environment["CLAUDEBOOK_TEST_SELECT_PAGES"] == "1", !selecting else { return }
        editMode = .active
        selection = Set(notebook.pages.prefix(2).map(\.id))
    }

    private func setSelecting(_ on: Bool) {
        withAnimation(Theme.Motion.pop) {
            selection = []
            editMode = on ? .active : .inactive
        }
    }

    @ViewBuilder
    private func actions(_ page: Page, index: Int) -> some View {
        Button { insert(at: index) } label: { Label("Insert page before", systemImage: "doc.badge.plus") }
        Button { insert(at: index + 1) } label: { Label("Insert page after", systemImage: "doc.badge.plus") }
        Button {
            mutate { api in try await api.duplicatePages([page.id], into: notebook.id, afterPage: index + 1).notebook }
        } label: { Label("Duplicate page", systemImage: "plus.square.on.square") }
        .accessibilityIdentifier("pages.duplicate.\(page.id)")
        Button { moving = [page.id] } label: { Label("Move to notebook…", systemImage: "book.closed") }
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

    private func mutate(discardingInk: Bool = false, endSelection: Bool = false, _ operation: @escaping (API) async throws -> Notebook) {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let api = API.current else { return }
                try await beforeMutation(discardingInk)
                let updated = try await operation(api)
                withAnimation(Theme.Motion.soft) { notebook = updated }
                if endSelection { setSelecting(false) }
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
    var count = 1
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
            .navigationTitle(count == 1 ? "Move page to…" : "Move \(count) pages to…")
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
