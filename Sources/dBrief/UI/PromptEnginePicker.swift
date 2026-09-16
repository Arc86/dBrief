import SwiftUI

struct PromptEnginePicker: View {
    @Bindable var session: PromptEditorSession
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("AI engine", selection: $session.engineSelection) {
                Text("Use settings").tag(PromptEngineSelection.configured)
                Divider()
                Text("Apple Intelligence").tag(PromptEngineSelection.appleIntelligence)
                Text("Gemma 4 E4B Local").tag(PromptEngineSelection.localModel)
                Text("Local CLI").tag(PromptEngineSelection.localCLI)
                if !session.store.settings.aiEndpoints.isEmpty {
                    Section("Configured endpoints") {
                        ForEach(session.store.settings.aiEndpoints) { endpoint in
                            Text("\(endpoint.name) · \(endpoint.modelName)").tag(PromptEngineSelection.remote(endpoint.id))
                        }
                    }
                }
                if case .remote(let id) = session.engineSelection,
                   !session.store.settings.aiEndpoints.contains(where: { $0.id == id }) {
                    Text("Unavailable endpoint").tag(session.engineSelection)
                }
            }.pickerStyle(.menu)
            Text(session.identity.kind == .voiceStyle && session.panel == .preview
                 ? "Applies to AI improvements. Audio uses your configured voice."
                 : "For this window only · app settings stay unchanged")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
