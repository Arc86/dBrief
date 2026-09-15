import SwiftUI
import dBriefWire

struct PromptPreviewPanel: View {
    @Environment(AppContext.self) private var context
    @Bindable var session: PromptEditorSession
    @State private var selectedID = PromptPreviewSample.example.id
    @State private var sample: PromptPreviewSample? = .example
    @State private var sampleError: String?
    @State private var loading = false
    @State private var refresh = UUID()
    private var preview: PromptPreviewSession { session.preview }
    private var settings: AppSettings { session.store.settings }
    private var isVoice: Bool { session.identity.kind == .voiceStyle }
    private var voiceSupported: Bool { settings.ttsEngine == .qwen3 && settings.ttsModelSize.supportsVoiceInstruction }
    private var voiceFingerprint: String {
        let tts = settings.ttsSynthesisParams
        return [tts.engine, tts.voice ?? "", tts.language ?? "", tts.model ?? "", session.draft.text].joined(separator: "\n")
    }
    private var choices: [Recording] {
        context.appState.recentRecordings.filter {
            $0.transcription != nil || $0.richTranscript != nil || $0.transcriptSidecarURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
    }
    private var usesSpokenFallback: Bool {
        session.identity.kind == .spokenSummary && settings.aiEngine == .localCLI
    }
    private func route() throws -> PromptExecutionConfiguration {
        if usesSpokenFallback {
            switch settings.chatFallbackEngine {
            case .appleIntelligence: return .appleIntelligence
            case .qwenLocal: return .localModel
            case .remoteEndpoint:
                guard let endpoint = settings.defaultAIEndpoint else { throw PromptAIError.missingEndpoint }
                try PromptConfigurationResolver.validate(endpoint)
                return .remote(endpoint)
            case .localCLI: throw PromptPreviewError.failed("Choose a chat fallback engine in AI settings for spoken-summary previews.")
            }
        }
        return try PromptConfigurationResolver.resolve(identity: session.identity, settings: settings)
    }
    private var request: PromptPreviewRequest? {
        guard !isVoice, let sample, let config = try? route() else { return nil }
        let scope = session.identity.scope
        let store = session.store
        guard let summary = try? store.load(.init(kind: .summary, scope: scope)),
              let actions = try? store.load(.init(kind: .actionItems, scope: scope)),
              let tags = try? store.load(.init(kind: .tags, scope: scope)) else { return nil }
        let profile: MeetingProfile? = if case .profile(let id) = scope { settings.profiles.first { $0.id == id } } else { nil }
        return .init(identity: session.identity, draftText: session.draft.text, sample: sample, configuration: config,
                     outputLanguage: settings.outputLanguage, vocabulary: (profile?.overrides.customVocabulary ?? settings.customVocabulary).joined(separator: ", "),
                     summaryGuidance: PromptDraft(snapshot: summary).text, actionItemsGuidance: PromptDraft(snapshot: actions).text,
                     tagsGuidance: PromptDraft(snapshot: tags).text)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(isVoice ? "Try the voice style" : "Try your prompt").font(.headline)
                if isVoice { voiceControls } else { textControls }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: "\(selectedID)-\(refresh)") { await loadSample() }
        .onReceive(NotificationCenter.default.publisher(for: .recordingLibraryChanged).receive(on: RunLoop.main)) { _ in
            preview.cancel(); refresh = UUID()
        }
        .onChange(of: request) { _, _ in preview.cancel() }
        .onChange(of: voiceFingerprint) { _, _ in preview.cancel() }
        .onDisappear { preview.cancel() }
    }
    @ViewBuilder private var textControls: some View {
        Picker("Recording", selection: $selectedID) {
            Text(PromptPreviewSample.example.title).tag(PromptPreviewSample.example.id)
            ForEach(choices) { recording in Text(recording.generatedTitle ?? recording.fileURL.deletingPathExtension().lastPathComponent).tag(recording.id) }
        }.pickerStyle(.menu)
        if let config = try? route() {
            Text(config.displayName).fontWeight(.medium)
            Text(config.destinationDescription).font(.callout).foregroundStyle(.secondary)
            if usesSpokenFallback {
                Text("Uses your configured chat fallback, matching spoken-summary generation.").font(.callout).foregroundStyle(.secondary)
            }
            if case .remote = config { Text("Sends the selected text to this endpoint.").font(.callout).foregroundStyle(.secondary) }
            if case .localCLI = config { Text("Your command determines where the selected text is processed.").font(.callout).foregroundStyle(.secondary) }
        } else {
            Text(routeError).foregroundStyle(.secondary)
        }
        if loading { ProgressView("Loading transcript…") }
        if let sampleError { Text(sampleError).font(.callout).foregroundStyle(.secondary) }
        if session.identity.kind == .spokenSummary, sample?.summary == nil {
            Text("This recording has no saved summary. Use the example or choose a recording with saved insights.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let note = request?.shorteningNotice { Text(note).font(.caption).foregroundStyle(.secondary) }
        HStack {
            if preview.isRunning {
                ProgressView().controlSize(.small)
                Text("Generating preview…")
                Button("Cancel") { preview.cancel() }
            } else {
                Button("Run test") {
                    if let request, request.sample.id == selectedID {
                        let completion = PromptAIService(aiService: context.recordingManager.aiService,
                            localCLIService: context.recordingManager.localCLIService, localPlugin: context.recordingManager.localPlugin)
                        let service = PromptPreviewService(backends: .live(ai: context.recordingManager.aiService,
                            plugin: context.recordingManager.localPlugin, cli: context.recordingManager.localCLIService), completion: completion)
                        preview.start(request, using: service)
                    }
                }.disabled(loading || request == nil || session.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (session.identity.kind == .spokenSummary && sample?.summary == nil))
            }
        }
        Text("The original recording stays unchanged.").font(.caption).foregroundStyle(.secondary)
        if let error = preview.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        Divider()
        if let result = preview.result {
            if preview.resultRequest != request {
                Label("Outdated preview — run another test", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
            } else { Text("Preview result").font(.headline) }
            Text(result.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
        } else {
            Text("Your preview appears here").font(.headline).foregroundStyle(.secondary)
            Text("Choose a recording and run a test.").foregroundStyle(.secondary)
        }
    }
    private var routeError: String { do { _ = try route(); return "" } catch { return error.localizedDescription } }
    @ViewBuilder private var voiceControls: some View {
        Text("Uses the configured voice on this Mac.").foregroundStyle(.secondary)
        Text(settings.ttsLanguage.sampleText).font(.system(size: 16)).lineSpacing(4)
        if !voiceSupported { Text(PromptPreviewError.unsupportedVoice.localizedDescription).foregroundStyle(.secondary) }
        if preview.voice.isBusy {
            if preview.voice.isPlaying { Label("Playing sample", systemImage: "speaker.wave.2") }
            else { ProgressView("Preparing voice sample…") }
            Button("Stop") { preview.voice.stop() }
        } else {
            Button("Play sample") {
                let tts = settings.ttsSynthesisParams
                preview.voice.preview(text: settings.ttsLanguage.sampleText, engine: tts.engine, voice: tts.voice,
                    language: tts.language, instruction: session.draft.text, model: tts.model, plugin: context.recordingManager.localPlugin)
            }.disabled(!voiceSupported || session.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if case .failed(let message) = preview.voice.state { SettingsErrorDetails(summary: "Voice preview failed", error: message) }
        Text("Sample audio is temporary. Your saved voice style stays unchanged.").font(.caption).foregroundStyle(.secondary)
    }

    @MainActor private func loadSample() async {
        let id = selectedID
        if id == PromptPreviewSample.example.id { sample = .example; sampleError = nil; return }
        guard let recording = context.appState.recentRecordings.first(where: { $0.id == id }) else {
            sample = nil; sampleError = "This recording is no longer available. Choose the example."; return
        }
        loading = true
        defer { loading = false }
        do {
            var rich = recording.richTranscript
            if let url = recording.transcriptSidecarURL, FileManager.default.fileExists(atPath: url.path) {
                rich = try await context.transcriptStore.load(from: url)
            }
            var summary = recording.summary
            var actions = recording.actionItems
            if let url = recording.insightsSidecarURL, let insights = try await context.insightsStore.load(from: url) {
                summary = insights.summary; actions = insights.actionItems
            }
            let text: String
            if let rich {
                let names = Dictionary(rich.speakerLabels.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
                text = rich.segments.map { segment in
                    let label = segment.speakerId.map { names[$0] ?? $0 }
                    return label.map { "\($0): \(segment.text)" } ?? segment.text
                }.joined(separator: "\n")
            } else { text = recording.transcription?.textForLLM(speakerNames: [:]) ?? "" }
            try Task.checkCancellation()
            guard id == selectedID else { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptPreviewError.emptyTranscript }
            sample = .init(id: id, title: recording.generatedTitle ?? recording.fileURL.lastPathComponent,
                transcript: text, summary: summary, actionItems: actions, participants: recording.participants, calendarEvent: recording.calendarEvent)
            sampleError = nil
        } catch {
            if id == selectedID && !Task.isCancelled {
                sample = nil
                sampleError = "Could not load this transcript. Choose another recording or the example."
            }
        }
    }
}
