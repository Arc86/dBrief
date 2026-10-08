import SwiftUI
import dBriefWire

struct SettingsTranscriptionTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    private var searchAdvanced: Bool { searchRequest?.section.isAdvanced ?? false }
    @Environment(\.settingsSearchRequest) private var searchRequest
    @Environment(RecordingManager.self) private var recordingManager
    @State private var purgeMessage: String?
    // Start from the built-in list so the model card (and its change-model button,
    // which also picks Parakeet / Apple Speech) never waits on the network.
    private static let offlineWhisperModels = WhisperModelInfo.fallbackModelNames
        .map { WhisperModelInfo.parse($0) }.sorted()
    @State private var whisperModels: [WhisperModelInfo] = Self.offlineWhisperModels
    @State private var isFetchingWhisperModels = false
    @State private var whisperModelFetchError: String?
    @State private var showWhisperComparison = false
    @State private var modernApple = false
    @State private var lastLocalEngine: AppSettings.TranscriptionEngine = .localWhisper
    @State private var newIgnoredPhrase = ""
    @State private var showIgnoredSegments = false
    let editProfile: (UUID) -> Void

    enum TestResult {
        case testing
        case success
        case failure(String)
    }

    private func fetchWhisperModels() {
        guard !isFetchingWhisperModels else { return }
        isFetchingWhisperModels = true
        whisperModelFetchError = nil
        Task {
            let modelNames = await recordingManager.fetchAvailableWhisperModels()
            if modelNames.isEmpty {
                whisperModels = Self.offlineWhisperModels
                whisperModelFetchError = "Using offline model list — couldn't reach HuggingFace."
            } else {
                whisperModels = modelNames.map { WhisperModelInfo.parse($0) }.sorted()
            }
            isFetchingWhisperModels = false
        }
    }

    var body: some View {
        @Bindable var settings = appSettings
        let engine = settings.transcriptionEngine
        SettingsPageScaffold(page: .transcription, notice: {
            SettingsProfileScopeView(fields: SettingsPage.transcription.profileFields, editProfile: editProfile)
        }) {
            SettingsCard("Engine", section: .transcriptionEngine) {
                SettingsRow("Where transcription runs") {
                    Picker("Where transcription runs", selection: Binding(
                        get: { settings.transcriptionEngine == .remoteEndpoint },
                        set: { remote in
                            if remote {
                                lastLocalEngine = settings.transcriptionEngine
                                settings.transcriptionEngine = .remoteEndpoint
                            } else {
                                settings.transcriptionEngine = lastLocalEngine
                            }
                        }
                    )) {
                        Text("On this Mac").tag(false)
                        Text("Remote service").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                modelCard(engine: engine)
                if engine == .localWhisper, let error = whisperModelFetchError {
                    SettingsRow("Model list unavailable", caption: LocalizedStringKey(error)) {
                        SettingsStatusPill("Offline", kind: .warning)
                    }
                }
                if engine == .remoteEndpoint {
                    SettingsRow("Remote transcription", caption: "Uses the default provider below.")
                }
                if let purgeMessage {
                    SettingsRow(verbatim: "Model download", caption: purgeMessage)
                }
                SettingsStackedRow { TranscriptionEngineGuideView() }
            }

            SettingsCard("Language", section: .transcriptionLanguage) {
                SettingsRow("Spoken language", caption: languageCaption) { languagePicker }
            }

            SettingsCard("Cleanup", description: "Markup and hallucination artifacts are always removed",
                         section: .transcriptionCleanup) {
                SettingsRow("Remove filler words", caption: "um, uh, you know. Off keeps transcripts verbatim.") {
                    Toggle("Remove filler words", isOn: $settings.removeFillerWords)
                }
                SettingsRow("Drop silence hallucinations",
                            caption: "Removes whole lines such as “Thanks for watching”. Real speech that contains a phrase is kept.") {
                    Toggle("Drop silence hallucinations", isOn: $settings.removeIgnoredSegments)
                }
                if settings.removeIgnoredSegments {
                    SettingsStackedRow {
                        DisclosureGroup(isExpanded: $showIgnoredSegments) {
                            customIgnoredSegmentsEditor.padding(.top, 8)
                        } label: {
                            Text("Custom phrases (\(settings.customIgnoredSegments.count)) · \(TranscriptCleanup.defaultIgnoredSegments.count) built-in")
                                .uiFont(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.heading.color)
                        }
                    }
                }
            }

            SettingsCard("Live preview", section: .transcriptionLive) {
                SettingsRow("Transcribe while recording",
                            caption: "A quick on-device preview (and live chat). The final transcript still comes from the engine above.") {
                    Toggle("Transcribe while recording", isOn: $settings.liveTranscriptionEnabled)
                }
            }

            if engine == .remoteEndpoint || searchRequest?.section == .transcriptionServices {
                SettingsCard("Providers", description: "For remote transcription", section: .transcriptionServices) {
                    SettingsProviderList(kind: .transcription, endpoints: $settings.transcriptionEndpoints,
                                         defaultID: $settings.defaultTranscriptionEndpointId)
                }
            }

            SettingsAdvancedCard(page: .transcription, summary: "Compute, warm-up, large files",
                                 sections: [.transcriptionAdvanced, .transcriptionChunking]) {
                SettingsCard("Whisper", description: "On-device Whisper only", section: .transcriptionAdvanced) {
                    SettingsRow("Where it runs", caption: "Leave on Automatic unless large models fail.") {
                        Picker("Where it runs", selection: $settings.whisperComputeUnits) {
                            ForEach(AppSettings.WhisperComputeUnits.allCases, id: \.self) { unit in
                                Text(unit.friendlyName).tag(unit)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    SettingsRow("Keep the model warm", caption: "Loads after launch and wake to start faster. Keeps memory in use while idle.") {
                        Toggle("Keep the model warm", isOn: $settings.prewarmWhisperOnLaunch)
                    }
                    SettingsRow("Model list", caption: "Fetched from Hugging Face.") {
                        Button {
                            fetchWhisperModels()
                        } label: {
                            Label(isFetchingWhisperModels ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.settingsSecondary)
                        .disabled(isFetchingWhisperModels)
                    }
                }
                SettingsCard("Large files", description: "Remote services only", section: .transcriptionChunking) {
                    SettingsRow("Split large files",
                                caption: "Chunks are transcribed in order and merged. Native cloud diarization uses one file.") {
                        Toggle("Split large files", isOn: $settings.remoteChunkingEnabled)
                    }
                    if settings.remoteChunkingEnabled {
                        stepperRow("Max upload size", "\(settings.remoteChunkMaxUploadMB) MB",
                                   value: $settings.remoteChunkMaxUploadMB, in: 1...100)
                        stepperRow("Overlap", "\(Int(settings.remoteChunkOverlapSeconds)) s",
                                   value: $settings.remoteChunkOverlapSeconds, in: 0...15)
                        stepperRow("Retries", "\(settings.remoteChunkRetryCount)",
                                   value: $settings.remoteChunkRetryCount, in: 0...5)
                    }
                }
            }
        }
        .sheet(isPresented: $showWhisperComparison) {
            WhisperModelPicker(modelIDs: whisperModels.map(\.id),
                selectedID: LocalTranscriptionChoice.id(engine: appSettings.transcriptionEngine,
                    whisper: appSettings.whisperModelName, parakeet: appSettings.parakeetModelVariant),
                language: appSettings.transcriptionLanguage, identifySpeakers: appSettings.diarizationEnabled) { id in
                    let engine = LocalTranscriptionChoice.engine(id)
                    if engine == .localWhisper { appSettings.whisperModelName = id }
                    if let variant = LocalTranscriptionChoice.parakeetVariant(id) {
                        appSettings.parakeetModelVariant = variant
                    }
                    appSettings.transcriptionEngine = engine
                    lastLocalEngine = engine
                }
        }
        .onAppear {
            fetchWhisperModels()
            if appSettings.transcriptionEngine != .remoteEndpoint { lastLocalEngine = appSettings.transcriptionEngine }
        }
        .task(id: appSettings.transcriptionLanguage) {
            if #available(macOS 26, *) {
                let supported = await AppleSpeechAnalyzerService.supports(locale: appSettings.transcriptionLanguage.isEmpty
                    ? .current : Locale(identifier: appSettings.transcriptionLanguage))
                guard !Task.isCancelled else { return }
                modernApple = supported
            }
        }
    }

    // MARK: Engine

    @ViewBuilder
    private func modelCard(engine: AppSettings.TranscriptionEngine) -> some View {
        switch engine {
        case .appleSpeech:
            SettingsStackedRow {
                VStack(alignment: .leading, spacing: 8) {
                    TranscriptionModelCard(presentation: .local(LocalTranscriptionChoice.apple, modernApple: modernApple),
                                           onChangeModel: { showWhisperComparison = true }) {
                        SettingsStatusPill("Managed by macOS", kind: .neutral)
                    }
                    DisclosureGroup("Memory and sources") {
                        LocalModelEvidenceView(modelID: LocalTranscriptionChoice.apple)
                    }
                    .uiFont(.system(size: 12))
                }
            }
        case .parakeetLocal:
            let id = LocalTranscriptionChoice.id(engine: .parakeetLocal, whisper: "", parakeet: appSettings.parakeetModelVariant)
            SettingsStackedRow {
                VStack(alignment: .leading, spacing: 8) {
                    TranscriptionModelCard(presentation: .local(id), onChangeModel: { showWhisperComparison = true }) {
                        HStack(spacing: 6) {
                            ModelDownloadButton(kind: .parakeet, compact: true)
                            removeDownloadMenu(label: "Parakeet") { try await recordingManager.purgeLocalParakeetModel() }
                        }
                    }
                    DisclosureGroup("Memory and sources") {
                        LocalModelEvidenceView(modelID: id)
                    }
                    .uiFont(.system(size: 12))
                }
            }
        case .localWhisper:
            SettingsStackedRow {
                VStack(alignment: .leading, spacing: 8) {
                    TranscriptionModelCard(modelID: appSettings.whisperModelName,
                                           onChangeModel: { showWhisperComparison = true }) {
                        HStack(spacing: 6) {
                            ModelDownloadButton(kind: .whisper, compact: true)
                            removeDownloadMenu(label: "WhisperKit") { try await recordingManager.purgeLocalWhisperModel() }
                        }
                    }
                    .help("Smaller models are faster but less accurate. Larger models are more accurate but use more memory and time. Ratings are estimates.")
                    DisclosureGroup("Memory and sources") {
                        WhisperModelImpactView(modelID: appSettings.whisperModelName,
                                               identifySpeakers: appSettings.diarizationEnabled)
                            .padding(.top, 8)
                    }
                    .uiFont(.system(size: 12))
                }
            }
        case .remoteEndpoint:
            EmptyView()
        }
    }

    private func removeDownloadMenu(label: String, purge: @escaping () async throws -> Void) -> some View {
        Menu {
            Button("Remove downloaded model", role: .destructive) {
                Task {
                    do {
                        try await purge()
                        purgeMessage = "Local \(label) model cache removed."
                    } catch {
                        purgeMessage = error.localizedDescription
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More model actions")
    }

    // MARK: Language

    @ViewBuilder
    private var languagePicker: some View {
        @Bindable var settings = appSettings
        if settings.transcriptionEngine == .appleSpeech {
            AppleSpeechLanguagePicker(selection: $settings.transcriptionLanguage)
        } else {
            Picker("Spoken language", selection: $settings.transcriptionLanguage) {
                Text("Auto-detect").tag("")
                Divider()
                ForEach(Self.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .pickerStyle(.menu)
            .disabled(settings.transcriptionEngine == .parakeetLocal)
        }
    }

    private static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("nl", "Dutch"), ("de", "German"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("pt", "Portuguese"), ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"),
        ("ru", "Russian"), ("ar", "Arabic"), ("hi", "Hindi"), ("pl", "Polish"), ("tr", "Turkish"),
        ("uk", "Ukrainian"), ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"),
    ]

    private var languageCaption: LocalizedStringKey? {
        let settings = appSettings
        if settings.transcriptionEngine == .parakeetLocal {
            return "Parakeet detects the language itself. This choice is kept for other engines."
        } else if settings.transcriptionEngine == .appleSpeech && settings.transcriptionLanguage.isEmpty {
            return "Apple Speech uses the system language when set to Auto."
        } else if settings.transcriptionLanguage.isEmpty {
            return "Auto-detect works best for mixed-language meetings."
        }
        return nil
    }

    // MARK: Cleanup

    private var customIgnoredSegmentsEditor: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a phrase to ignore", text: $newIgnoredPhrase)
                    .settingsTextField()
                    .onSubmit { addIgnoredPhrase() }
                Button("Add", action: addIgnoredPhrase)
                    .buttonStyle(.settingsSecondary)
                    .disabled(newIgnoredPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if settings.customIgnoredSegments.isEmpty {
                Text("No custom phrases. Built-in phrases always apply while this is on.")
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(palette.secondary.color)
            } else {
                ForEach(settings.customIgnoredSegments, id: \.self) { phrase in
                    HStack {
                        Text(phrase).uiFont(.system(size: 12)).foregroundStyle(palette.text.color)
                        Spacer()
                        Button {
                            settings.customIgnoredSegments.removeAll { $0 == phrase }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(palette.secondary.color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(phrase)")
                    }
                }
                Button("Reset to defaults") { settings.customIgnoredSegments = [] }
                    .buttonStyle(.settingsSecondary)
            }
        }
    }

    private func addIgnoredPhrase() {
        let trimmed = newIgnoredPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // De-dupe case-insensitively against existing custom phrases.
        if !appSettings.customIgnoredSegments.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            appSettings.customIgnoredSegments.append(trimmed)
        }
        newIgnoredPhrase = ""
    }

    private func stepperRow<V: Strideable>(_ label: LocalizedStringKey, _ value: String, value binding: Binding<V>,
                                           in range: ClosedRange<V>) -> some View where V.Stride: ExpressibleByIntegerLiteral {
        SettingsRow(label) {
            HStack(spacing: 6) {
                Text(value).uiFont(.system(size: 12).monospacedDigit()).foregroundStyle(palette.text.color)
                Stepper(label, value: binding, in: range, step: 1)
            }
        }
    }
}
