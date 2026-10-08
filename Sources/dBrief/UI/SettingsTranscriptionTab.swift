import SwiftUI
import dBriefWire

struct SettingsTranscriptionTab: View {
    @Environment(AppSettings.self) private var appSettings
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
    @State private var showModelHelp = false
    @State private var modernApple = false
    @State private var lastLocalEngine: AppSettings.TranscriptionEngine = .localWhisper
    @State private var newIgnoredPhrase = ""
    @State private var showIgnoredSegments = false

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
            Form {
                Section("Engine", settingsSearch: .transcriptionEngine) { engineSection }
                    .listRowBackground(Color.clear)
                Section("Language", settingsSearch: .transcriptionLanguage) { languageSection }
                    .listRowBackground(Color.clear)
                Section("Cleanup", settingsSearch: .transcriptionCleanup) { cleanupSection }
                    .listRowBackground(Color.clear)
                Section("Live Transcription", settingsSearch: .transcriptionLive) { liveTranscriptionSection }
                    .listRowBackground(Color.clear)
                if appSettings.transcriptionEngine == .remoteEndpoint || searchRequest?.section == .transcriptionServices || searchRequest?.section == .transcriptionChunking {
                    Section("Transcription Services", settingsSearch: .transcriptionServices) {
                        VStack(spacing: 0) {
                            SettingsProviderList(kind: .transcription, endpoints: $settings.transcriptionEndpoints,
                                                 defaultID: $settings.defaultTranscriptionEndpointId)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    if appSettings.powerUserMode || searchAdvanced {
                        Section("Large File Handling", settingsSearch: .transcriptionChunking) {
                            if appSettings.transcriptionEngine != .remoteEndpoint {
                                Text("These options apply to remote transcription services.")
                                    .uiFont(.caption).foregroundStyle(.secondary)
                            }
                            chunkingSection
                        }
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .settingsFormStyle()
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

    private func formatMemory(_ mb: Int) -> String {
        let gb = Double(mb) / 1_024
        return String(format: "%.1f GB", gb)
    }

    private var liveTranscriptionSection: some View {
        @Bindable var settings = appSettings
        return Toggle(isOn: $settings.liveTranscriptionEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribe live while recording")
                Text("Real-time preview (and live chat) using Apple's on-device speech, with your mic and the meeting audio labeled separately. The final transcript still uses your chosen engine.")
                    .uiFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var engineSection: some View {
        @Bindable var settings = appSettings
        Picker("Transcription", selection: Binding(
            get: { settings.transcriptionEngine == .remoteEndpoint },
            set: { remote in
                if remote {
                    lastLocalEngine = settings.transcriptionEngine
                    settings.transcriptionEngine = .remoteEndpoint
                } else { settings.transcriptionEngine = lastLocalEngine }
            })) {
                Text("On this Mac").tag(false)
                Text("Remote service").tag(true)
            }.pickerStyle(.segmented)

        switch settings.transcriptionEngine {
        case .appleSpeech:
            TranscriptionModelCard(presentation: .local(LocalTranscriptionChoice.apple, modernApple: modernApple),
                                   onChangeModel: { showWhisperComparison = true }) {
                Label("macOS managed", systemImage: "apple.logo").uiFont(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Memory and sources") {
                LocalModelEvidenceView(modelID: LocalTranscriptionChoice.apple)
            }
        case .parakeetLocal:
            parakeetSection
        case .localWhisper:
            whisperSection
        case .remoteEndpoint:
            Text("Use a remote Whisper API or server. Requires an endpoint.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
        }

        TranscriptionEngineGuideView()
    }

    @ViewBuilder
    private var parakeetSection: some View {
        @Bindable var settings = appSettings
        VStack(alignment: .leading, spacing: 8) {
            let id = LocalTranscriptionChoice.id(engine: .parakeetLocal, whisper: "",
                                                 parakeet: settings.parakeetModelVariant)
            TranscriptionModelCard(presentation: .local(id),
                                   onChangeModel: { showWhisperComparison = true }) {
                ModelDownloadButton(kind: .parakeet, compact: true)
            }
            DisclosureGroup("Memory and sources") {
                LocalModelEvidenceView(modelID: id)
            }.uiFont(.caption)

            Toggle("Identify speakers", isOn: $settings.diarizationEnabled)
            Text("Identifies who said what via SpeakerKit, after transcription. Adds processing time and ~500 MB memory.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)

            Button("Remove downloaded Parakeet model") {
                Task {
                    do {
                        try await recordingManager.purgeLocalParakeetModel()
                        purgeMessage = "Local Parakeet model cache removed."
                    } catch {
                        purgeMessage = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.typographyBordered)
            .controlSize(.small)
            if let purgeMessage {
                Text(purgeMessage)
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var whisperSection: some View {
        @Bindable var settings = appSettings

        VStack(alignment: .leading, spacing: 10) {
            // — Model group header with help popover —
            HStack(spacing: 6) {
                Text("Model")
                    .uiFont(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    showModelHelp.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.typographyBorderless)
                .controlSize(.small)
                .popover(isPresented: $showModelHelp, arrowEdge: .bottom) {
                    Text("Smaller models are faster but less accurate. Larger models are more accurate but use more memory and time. When in doubt, keep the recommended one.")
                        .uiFont(.callout)
                        .padding()
                        .frame(width: 260)
                }
            }

            // — Model card —
            TranscriptionModelCard(modelID: settings.whisperModelName,
                                   onChangeModel: { showWhisperComparison = true }) {
                ModelDownloadButton(kind: .whisper, compact: true)
            }

            HStack {
                Text("Estimated ratings").uiFont(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            DisclosureGroup("Memory and sources") {
                WhisperModelImpactView(modelID: settings.whisperModelName,
                                       identifySpeakers: settings.diarizationEnabled)
                    .padding(.top, 8)
            }.uiFont(.caption)

            // — Offline fetch error (shown at top level so it's visible without expanding Advanced) —
            if let error = whisperModelFetchError {
                Label(error, systemImage: "wifi.slash")
                    .uiFont(.caption)
                    .foregroundStyle(.orange)
            }

            // — Diarization (plain label, jargon in caption) —
            Divider().padding(.vertical, 6)
            Text("Speakers").uiFont(.subheadline).foregroundStyle(.secondary)
            Toggle(isOn: $settings.diarizationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify different speakers")
                    Text("Diarization — labels who said what. Slower, uses ~500 MB more memory.")
                        .uiFont(.caption).foregroundStyle(.secondary)
                }
            }

            // — Confirm-first speaker review (only meaningful while diarizing) —
            if settings.diarizationEnabled {
                Picker(selection: $settings.speakerIdMode) {
                    ForEach(AppSettings.SpeakerIdMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When a voice is recognized")
                        Text(settings.speakerIdMode.shortDescription)
                            .uiFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .pickerStyle(.menu)
            }

            // — Advanced (collapsed) —
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Where it runs")
                            Text("Compute units. Leave on Automatic unless transcription fails on large models.")
                                .uiFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.whisperComputeUnits) {
                            ForEach(AppSettings.WhisperComputeUnits.allCases, id: \.self) { unit in
                                Text(unit.friendlyName).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }

                    Toggle(isOn: $settings.prewarmWhisperOnLaunch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep model warm")
                            Text("Loads the Whisper model shortly after launch and after the Mac wakes, to reduce startup time. Can retain model memory while idle.")
                                .uiFont(.caption).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button {
                            fetchWhisperModels()
                        } label: {
                            Label("Refresh model list", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.typographyBorderless)
                        .controlSize(.small)
                        .help("Refresh model list from HuggingFace")
                        Spacer()
                    }

                    Button("Remove downloaded WhisperKit model") {
                        Task {
                            do {
                                try await recordingManager.purgeLocalWhisperModel()
                                purgeMessage = "Local WhisperKit model cache removed."
                            } catch {
                                purgeMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.typographyBordered)
                    .controlSize(.small)
                    if let purgeMessage {
                        Text(purgeMessage)
                            .uiFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced").uiFont(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var languageSection: some View {
        @Bindable var settings = appSettings
        if settings.transcriptionEngine == .appleSpeech {
            AppleSpeechLanguagePicker(selection: $settings.transcriptionLanguage)
        } else {
            Picker("Audio language", selection: $settings.transcriptionLanguage) {
                Text(settings.transcriptionEngine == .appleSpeech ? "Auto (System language)" : "Auto-detect").tag("")
                Divider()
                Text("English").tag("en")
                Text("Dutch").tag("nl")
                Text("German").tag("de")
                Text("French").tag("fr")
                Text("Spanish").tag("es")
                Text("Italian").tag("it")
                Text("Portuguese").tag("pt")
                Text("Japanese").tag("ja")
                Text("Chinese").tag("zh")
                Text("Korean").tag("ko")
                Text("Russian").tag("ru")
                Text("Arabic").tag("ar")
                Text("Hindi").tag("hi")
                Text("Polish").tag("pl")
                Text("Turkish").tag("tr")
                Text("Ukrainian").tag("uk")
                Text("Swedish").tag("sv")
                Text("Danish").tag("da")
                Text("Norwegian").tag("no")
            }
            .pickerStyle(.menu)
            .disabled(settings.transcriptionEngine == .parakeetLocal)
        }
        if settings.transcriptionEngine == .parakeetLocal {
            Text("Parakeet determines the language from its model and the audio. This selection has no effect; it is kept for other engines.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
        } else if settings.transcriptionEngine == .appleSpeech && settings.transcriptionLanguage.isEmpty {
            Text("Apple Speech uses the system language when set to Auto.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
        } else if settings.transcriptionEngine == .localWhisper && settings.transcriptionLanguage.isEmpty {
            Text("WhisperKit auto-detects language when set to Auto-detect.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cleanupSection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Remove filler words (um, uh, …)", isOn: $settings.removeFillerWords)
                Text("Markup and hallucination artifacts are always cleaned. Filler removal is off by default so meeting transcripts stay verbatim.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ignoredSegmentsSection
        }
    }

    private var ignoredSegmentsSection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Filter ignored segments", isOn: $settings.removeIgnoredSegments)
            Text("Drops segments that exactly match a known filler phrase — Whisper silence-hallucinations like “Thank you for watching”, “Subscribe to the channel”, or “♪”. Matching is whole-segment, so real speech that merely contains a phrase is kept.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)

            if settings.removeIgnoredSegments {
                DisclosureGroup(isExpanded: $showIgnoredSegments) {
                    customIgnoredSegmentsEditor
                } label: {
                    Text("Custom phrases (\(settings.customIgnoredSegments.count)) · \(TranscriptCleanup.defaultIgnoredSegments.count) built-in")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var customIgnoredSegmentsEditor: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a phrase to ignore", text: $newIgnoredPhrase)
                    .settingsTextField()
                    .onSubmit { addIgnoredPhrase() }
                Button("Add", action: addIgnoredPhrase)
                    .disabled(newIgnoredPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if settings.customIgnoredSegments.isEmpty {
                Text("No custom phrases. Built-in phrases are always applied while filtering is on.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.customIgnoredSegments, id: \.self) { phrase in
                    HStack {
                        Text(phrase)
                            .uiFont(.callout)
                        Spacer()
                        Button {
                            settings.customIgnoredSegments.removeAll { $0 == phrase }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove phrase")
                    }
                }

                Button("Reset to Defaults") {
                    settings.customIgnoredSegments = []
                }
                .uiFont(.caption)
            }
        }
        .padding(.top, 4)
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

    private var chunkingSection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable chunking for large files", isOn: $settings.remoteChunkingEnabled)

            if settings.remoteChunkingEnabled {
                LabeledContent("Max upload size") {
                    Stepper(
                        "\(settings.remoteChunkMaxUploadMB) MB",
                        value: $settings.remoteChunkMaxUploadMB,
                        in: 1...100
                    )
                    .frame(width: 180, alignment: .trailing)
                }

                LabeledContent("Overlap") {
                    Stepper(
                        "\(Int(settings.remoteChunkOverlapSeconds)) sec",
                        value: $settings.remoteChunkOverlapSeconds,
                        in: 0...15,
                        step: 1
                    )
                    .frame(width: 180, alignment: .trailing)
                }

                LabeledContent("Retry count") {
                    Stepper(
                        "\(settings.remoteChunkRetryCount)",
                        value: $settings.remoteChunkRetryCount,
                        in: 0...5
                    )
                    .frame(width: 180, alignment: .trailing)
                }

                Text("Large files are split into smaller chunks, transcribed sequentially, and merged into a single timeline.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Hosted providers may enforce a smaller upload limit. Files above the effective limit are split automatically when the endpoint supports it. Native cloud diarization uses a single file.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
