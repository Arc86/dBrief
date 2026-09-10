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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Terms you add here help the AI understand your domain. After transcription, the AI corrects misspellings of these terms in the transcript. During analysis, they're provided to generate more accurate summaries and action items.")
                    Text("Add names, acronyms, product names, and technical terms your recordings commonly include.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    TextField("Add a term…", text: $newTermText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit { addTerm() }
                    Button("Add") { addTerm() }
                }
                if let addError {
                    Text(addError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let originalTerm = editor.originalTerm {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Editing “\(originalTerm)”")
                            .font(.callout)
                        HStack {
                            TextField("Term", text: $editor.text)
                                .textFieldStyle(.roundedBorder)
                                .focused($editFocused)
                                .onSubmit { saveEdit() }
                            Button("Save") { saveEdit() }
                                .keyboardShortcut(.defaultAction)
                            Button("Cancel") { editor.cancel() }
                                .keyboardShortcut(.cancelAction)
                        }
                        if let error = editor.error {
                            Text(error)
                                .font(.callout)
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
                        Button("Edit") { startEdit(at: index, term: term) }
                            .disabled(editor.isEditing)
                            .accessibilityLabel("Edit \(term)")
                        Button("Delete", role: .destructive) { deleteTerm(at: index, term: term) }
                            .disabled(editor.originalTerm == term)
                            .accessibilityLabel("Delete \(term)")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                SettingsSearchHeading("Terms", section: .vocabularyTerms)
            } footer: {
                Text("Choose Edit or double-click a term. Save applies your change; Cancel discards it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulary")
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
