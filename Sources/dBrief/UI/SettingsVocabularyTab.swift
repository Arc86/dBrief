import SwiftUI

@MainActor
struct SettingsVocabularyTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var editor = VocabularyEditing()
    @State private var newTermText = ""
    @State private var addError: String?
    @FocusState private var editFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("New term", text: $newTermText, prompt: Text("Add a name, acronym, or product…"))
                        .labelsHidden()
                        .settingsTextField()
                        .frame(maxWidth: .infinity)
                        .onSubmit { addTerm() }
                    Button("Add") { addTerm() }
                        .disabled(newTermText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let addError {
                    Text(addError)
                        .uiFont(.callout)
                        .foregroundStyle(.red)
                }
                if let originalTerm = editor.originalTerm {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Editing “\(originalTerm)”")
                            .uiFont(.callout)
                        HStack {
                            TextField("Term", text: $editor.text)
                                .settingsTextField()
                                .focused($editFocused)
                                .onSubmit { saveEdit() }
                            Button("Save") { saveEdit() }
                                .keyboardShortcut(.defaultAction)
                            Button("Cancel") { editor.cancel() }
                                .keyboardShortcut(.cancelAction)
                        }
                        if let error = editor.error {
                            Text(error)
                                .uiFont(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                    .onExitCommand { editor.cancel() }
                }
                ForEach(Array(appSettings.customVocabulary.enumerated()), id: \.offset) { index, term in
                    HStack {
                        Text(term)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { startEdit(at: index, term: term) }
                        Button { startEdit(at: index, term: term) } label: {
                            Image(systemName: "pencil")
                        }
                        .disabled(editor.isEditing)
                        .help("Edit")
                        .accessibilityLabel("Edit \(term)")
                        Button(role: .destructive) { deleteTerm(at: index, term: term) } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(editor.originalTerm == term)
                        .help("Delete")
                        .accessibilityLabel("Delete \(term)")
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
                if appSettings.customVocabulary.isEmpty {
                    Text("No terms yet.")
                        .uiFont(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SettingsSearchHeading("Terms", section: .vocabularyTerms)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("After transcription, AI corrects misspellings of these terms in the transcript. During analysis, they help produce more accurate summaries and action items.")
                    Text("Double-click a term, or use the pencil, to change it.")
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            }
            .listRowBackground(Color.clear)
        }
        .settingsFormStyle()
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
