import SwiftUI

@MainActor
struct SettingsVocabularyTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    let editProfile: (UUID) -> Void
    @State private var editor = VocabularyEditing()
    @State private var newTermText = ""
    @State private var addError: String?
    @FocusState private var editFocused: Bool

    var body: some View {
        SettingsPageScaffold(page: .vocabulary, notice: {
            SettingsProfileScopeView(fields: SettingsPage.vocabulary.profileFields, editProfile: editProfile)
        }) {
            SettingsCard("Terms", description: "Used to fix spelling after transcription and in AI prompts",
                         section: .vocabularyTerms) {
                SettingsStackedRow {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("New term", text: $newTermText, prompt: Text("Add a name, acronym or product…"))
                                .labelsHidden()
                                .settingsTextField()
                                .frame(maxWidth: .infinity)
                                .onSubmit { addTerm() }
                            Button("Add") { addTerm() }
                                .buttonStyle(.settingsPrimary)
                                .disabled(newTermText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let addError {
                            Text(addError).uiFont(.system(size: 11.5)).foregroundStyle(status.danger.color)
                        }
                    }
                }
                if let originalTerm = editor.originalTerm {
                    SettingsStackedRow {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Editing “\(originalTerm)”")
                                .uiFont(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.heading.color)
                            HStack {
                                TextField("Term", text: $editor.text)
                                    .settingsTextField()
                                    .focused($editFocused)
                                    .onSubmit { saveEdit() }
                                Button("Save") { saveEdit() }
                                    .buttonStyle(.settingsPrimary)
                                    .keyboardShortcut(.defaultAction)
                                Button("Cancel") { editor.cancel() }
                                    .buttonStyle(.settingsSecondary)
                                    .keyboardShortcut(.cancelAction)
                            }
                            if let error = editor.error {
                                Text(error).uiFont(.system(size: 11.5)).foregroundStyle(status.danger.color)
                            }
                        }
                        .onExitCommand { editor.cancel() }
                    }
                }
                // Offset identity: rows hold no state, and lists migrated from the legacy
                // Whisper prompt can contain duplicate terms, which would collide as ids.
                ForEach(Array(appSettings.customVocabulary.enumerated()), id: \.offset) { index, term in
                    SettingsRow(verbatim: term) {
                        HStack(spacing: 6) {
                            Button { startEdit(at: index, term: term) } label: { Image(systemName: "pencil") }
                                .disabled(editor.isEditing)
                                .help("Edit")
                                .accessibilityLabel("Edit \(term)")
                            Button(role: .destructive) { deleteTerm(at: index, term: term) } label: { Image(systemName: "trash") }
                                .disabled(editor.originalTerm == term)
                                .help("Delete")
                                .accessibilityLabel("Delete \(term)")
                        }
                        .buttonStyle(.settingsSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEdit(at: index, term: term) }
                }
                if appSettings.customVocabulary.isEmpty {
                    SettingsRow("No terms yet", caption: "Profiles can add their own terms on top of these.")
                }
            }
        }
    }

    private func startEdit(at index: Int, term: String) {
        guard appSettings.customVocabulary.indices.contains(index), appSettings.customVocabulary[index] == term else { return }
        editor.begin(at: index, in: appSettings.customVocabulary)
        editFocused = true
    }

    private func saveEdit() {
        var terms = appSettings.customVocabulary
        editor.save(in: &terms)
        if !editor.isEditing {
            appSettings.customVocabulary = terms
        }
    }

    private func deleteTerm(at index: Int, term: String) {
        guard appSettings.customVocabulary.indices.contains(index), appSettings.customVocabulary[index] == term else { return }
        appSettings.customVocabulary.remove(at: index)
    }

    private func addTerm() {
        switch VocabularyEditing.validate(newTermText, in: appSettings.customVocabulary) {
        case .success(let term):
            appSettings.customVocabulary.append(term)
            newTermText = ""
            addError = nil
        case .failure(let error):
            addError = error.message
        }
    }
}
