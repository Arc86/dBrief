import SwiftUI

struct PromptImprovementPanel: View {
    @Bindable var session: PromptEditorSession
    @State private var showRequest = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PromptInspectorHeading(title: "A better prompt", subtitle: "Describe what you’d like to change.", symbol: "sparkles")
                if let config = session.configuration {
                    VStack(alignment: .leading, spacing: 4) {
                        PromptEngineLabel(name: config.displayName, destination: config.destinationDescription)
                        if session.engineSelection == .configured, let note = PromptConfigurationResolver.fallbackExplanation(identity: session.identity, settings: session.store.settings) {
                            Text(note).foregroundStyle(.secondary)
                        }
                    }.uiFont(.callout)
                } else if let error = session.configurationError { Text(error).foregroundStyle(.secondary) }
                DisclosureGroup("Improvement request", isExpanded: $showRequest) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Improve clarity while preserving intent", text: $session.improvementRequest, axis: .vertical)
                            .lineLimit(3...6).textFieldStyle(.plain)
                            .padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("What would you like to improve?")
                        ViewThatFits(in: .horizontal) {
                            HStack { shortcuts }
                            VStack(alignment: .leading) { shortcuts }
                        }.buttonStyle(.typographyBordered).buttonBorderShape(.capsule).controlSize(.small)
                        Text("Uses this prompt and your request. No recording is sent.")
                            .uiFont(.callout).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                HStack {
                    if session.isImproving {
                        PromptGenerationStatus(progress: session.improvementProgress ?? .generating,
                            generationTitle: "Generating…", cancel: session.cancelImprovement)
                    } else {
                        Button { Task { await session.improve() } } label: { Label("Suggest improvements", systemImage: "sparkles") }
                            .modifier(PromptPrimaryAction())
                            .disabled(session.configuration == nil || session.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let error = session.improvementError { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                if let suggestion = session.suggestion {
                    Divider()
                    Text("Suggested prompt").uiFont(.headline)
                    ForEach(Array(suggestion.response.changes.enumerated()), id: \.offset) { _, change in
                        Text("• \(change)").uiFont(.callout).foregroundStyle(.secondary)
                    }
                    Text(suggestion.response.prompt).uiFont(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    if !session.canApplySuggestion {
                        Text("The prompt, request, or AI configuration changed. Generate a new suggestion.")
                            .uiFont(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Use suggestion") { session.applySuggestion() }
                            .modifier(PromptPrimaryAction()).disabled(!session.canApplySuggestion)
                        Button("Discard") { session.discardSuggestion() }
                    }
                    Text("Replaces the draft. Save when you’re ready.").uiFont(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: session.suggestion) { _, suggestion in if suggestion != nil { showRequest = false } }
    }
    @ViewBuilder private var shortcuts: some View {
        Button("Shorter") { session.improvementRequest = "Make it shorter while preserving important details." }
        Button("Clearer") { session.improvementRequest = "Make it clearer and more actionable." }
        Button("More specific") { session.improvementRequest = "Make it more specific about the expected output." }
    }
}
