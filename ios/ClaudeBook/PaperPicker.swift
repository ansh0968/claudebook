import SwiftUI

/// Functional picker only; paper previews call the same drawing entry point as the notebook.
struct PaperPicker: View {
    let notebook: Notebook
    let page: Page
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var background: PageBackground
    @State private var paper: PaperColor
    @State private var allPages = false
    @State private var saving = false
    @State private var error: String?

    init(notebook: Notebook, page: Page, onSaved: @escaping () async -> Void) {
        self.notebook = notebook; self.page = page; self.onSaved = onSaved
        _background = State(initialValue: page.background)
        _paper = State(initialValue: page.paper ?? .default)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Apply to") {
                    Picker("Pages", selection: $allPages) {
                        Text("This page").tag(false)
                        Text("All pages").tag(true)
                    }.pickerStyle(.segmented)
                }
                Section("Paper colour") {
                    Picker("Paper", selection: $paper) {
                        ForEach(PaperColor.allCases, id: \.self) { value in
                            Text(PaperTemplates.data.papers[value.rawValue]?.title ?? value.rawValue).tag(value)
                        }
                    }.accessibilityIdentifier("paper.color")
                    if paper.isDark { Text("Use a light pen on dark paper. The pen colour applies to the whole canvas; neighbouring light pages keep their appearance.") }
                    if page.pdf != nil { Text("PDF artwork covers the paper inside the PDF page.") }
                }
                Section("Page type") {
                    ForEach(PageBackground.allCases, id: \.self) { value in
                        Button {
                            background = value
                        } label: {
                            HStack {
                                Image(uiImage: preview(value)).resizable().frame(width: 46, height: 65)
                                Text(PaperTemplates.data.templates[value.rawValue]?.title ?? value.rawValue)
                                Spacer()
                                if background == value { Image(systemName: "checkmark") }
                            }
                        }.accessibilityIdentifier("paper.pattern.\(value.rawValue)")
                    }
                }
                if let error { Section { Text(error) } }
            }
            .tint(StudyPalette.teal)
            .navigationTitle("Page type")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        saving = true
                        Task {
                            do {
                                guard let api = API.current else { throw APIError(status: 0, body: "Connect to your notebook first") }
                                try await api.setBackground(pageIds: allPages ? notebook.pages.map(\.id) : [page.id], background: background, paper: paper)
                                await onSaved()
                                dismiss()
                            } catch { self.error = error.localizedDescription; saving = false }
                        }
                    }.disabled(saving).accessibilityIdentifier("paper.apply")
                }
            }
        }
    }

    private func preview(_ value: PageBackground) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 46, height: 65)).image { context in
            context.cgContext.scaleBy(x: 46 / PageGeometry.width, y: 65 / PageGeometry.height)
            PaperView.drawPaper(PaperStyle(background: value, paper: paper), in: context.cgContext)
        }
    }
}
