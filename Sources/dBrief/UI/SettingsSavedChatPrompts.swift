import SwiftUI

/// Saved Ask dBrief AI prompts: rename, edit, reorder by removing, or add one.
struct SettingsSavedChatPrompts: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @State private var newPrompt = ""

    var body: some View {
        @Bindable var settings = appSettings
        VStack(alignment: .leading, spacing: 10) {
            if settings.savedChatPrompts.isEmpty {
                Text("No saved prompts yet. In the chat, right-click a question and choose Save as Prompt.")
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(palette.secondary.color)
            } else {
                ForEach($settings.savedChatPrompts) { $prompt in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Chip title", text: $prompt.title)
                                .settingsTextField()
                                .accessibilityLabel("Prompt title")
                            TextField("Question", text: $prompt.prompt, axis: .vertical)
                                .lineLimit(1...4)
                                .settingsTextField()
                                .accessibilityLabel("Prompt question")
                        }
                        Button {
                            settings.savedChatPrompts.removeAll { $0.id == prompt.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(palette.secondary.color)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete this prompt")
                        .accessibilityLabel("Delete \(prompt.title)")
                    }
                    .padding(.bottom, 4)
                }
            }
            HStack {
                TextField("Add a question you ask often", text: $newPrompt)
                    .settingsTextField()
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.settingsSecondary)
                    .disabled(newPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func add() {
        let question = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if !appSettings.savedChatPrompts.contains(where: { $0.prompt == question }) {
            appSettings.savedChatPrompts.append(SavedChatPrompt(question: question))
        }
        newPrompt = ""
    }
}
