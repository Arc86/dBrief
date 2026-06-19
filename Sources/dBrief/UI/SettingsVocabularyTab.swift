import SwiftUI

@MainActor
struct SettingsVocabularyTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var editingIndex: Int? = nil
    @State private var editingText: String = ""
    @State private var newTermText: String = ""
    @State private var hoveredIndex: Int? = nil
    @FocusState private var editFocused: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Terms you add here help the AI understand your domain. After transcription, the AI corrects misspellings of these terms in the transcript. During analysis, they're provided to generate more accurate summaries and action items.")
                    Text("Add names, acronyms, product names, and technical terms your recordings commonly include.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 0) {
                    if appSettings.customVocabulary.isEmpty {
                        Text("No terms yet — add your first one below.")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(Array(appSettings.customVocabulary.enumerated()), id: \.offset) { index, term in
                            termRow(index: index, term: term)
                        }
                    }
                }
            } header: {
                Text("Terms")
            } footer: {
                Text("Double-click a term to edit it. Terms are applied as spelling hints during AI analysis.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("Add a term…", text: $newTermText)
                        .onSubmit { addTerm() }
                    Button("Add") { addTerm() }
                        .disabled(newTermText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulary")
    }

    @ViewBuilder
    private func termRow(index: Int, term: String) -> some View {
        HStack {
            if editingIndex == index {
                TextField("", text: $editingText)
                    .focused($editFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .onChange(of: editFocused) { _, focused in
                        if !focused { commitEdit() }
                    }
            } else {
                Text(term)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEdit(at: index, term: term) }
                    .onHover { isHovered in
                        hoveredIndex = isHovered ? index : (hoveredIndex == index ? nil : hoveredIndex)
                    }

                if hoveredIndex == index {
                    Button(role: .destructive) {
                        deleteTerm(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.1), value: hoveredIndex)
    }

    private func startEdit(at index: Int, term: String) {
        editingIndex = index
        editingText = term
        DispatchQueue.main.async { editFocused = true }
    }

    private func commitEdit() {
        guard let index = editingIndex else { return }
        editingIndex = nil
        let trimmed = editingText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let isDuplicate = appSettings.customVocabulary.enumerated().contains { i, t in
            i != index && t.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !isDuplicate else { return }
        @Bindable var settings = appSettings
        settings.customVocabulary[index] = trimmed
    }

    private func cancelEdit() {
        editingIndex = nil
        editingText = ""
    }

    private func deleteTerm(at index: Int) {
        hoveredIndex = nil
        @Bindable var settings = appSettings
        settings.customVocabulary.remove(at: index)
    }

    private func addTerm() {
        let trimmed = newTermText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let isDuplicate = appSettings.customVocabulary.contains {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if !isDuplicate {
            @Bindable var settings = appSettings
            settings.customVocabulary.append(trimmed)
        }
        newTermText = ""
    }
}
