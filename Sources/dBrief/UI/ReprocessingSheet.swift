import AppKit
import SwiftUI
import dBriefWire

/// Attempt settings are value copies; editing this sheet never changes a profile.
struct ReprocessingSheet: View {
    let recording: Recording
    let operation: ReprocessingOperation
    /// An unfinished run in Queue & Recovery to discard when Start is pressed.
    var discardingRunID: UUID? = nil
    var dismissAction: (() -> Void)? = nil
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var options: ReprocessingOptions?
    @State private var usingPrevious = false
    @State private var supportsCalendarReload = false

    var body: some View {
        Group {
            if let options {
                ReprocessingEditor(recording: recording, initialOptions: options,
                    usingPrevious: usingPrevious, supportsCalendarReload: supportsCalendarReload,
                    discardingRunID: discardingRunID, dismissAction: dismissAction)
            } else {
                VStack(spacing: 16) {
                    ProgressView("Loading settings…")
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(MenuPanelButtonStyle(kind: .secondary, fillsWidth: false))
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panelWindowChrome()
            }
        }
        .task {
            let previous = await manager.lastReprocessingOptions(for: recording)
            let canReload = await manager.canReloadCalendarParticipants(for: recording)
            guard !Task.isCancelled else { return }
            usingPrevious = previous != nil
            supportsCalendarReload = canReload
            var value = previous ?? ReprocessingOptions(settings: settings, operation: operation)
            value.operation = operation
            options = value
        }
    }

    private func close() {
        if let dismissAction { dismissAction() }
        else { dismiss() }
    }
}

private struct ReprocessingEditor: View {
    let recording: Recording
    let usingPrevious: Bool
    let supportsCalendarReload: Bool
    let discardingRunID: UUID?
    let dismissAction: (() -> Void)?
    @State private var options: ReprocessingOptions
    @State private var isStarting = false
    @State private var showWhisperComparison = false
    @State private var discoveredWhisperModels: [String] = []
    @State private var error: String?
    @Environment(RecordingManager.self) private var manager
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.viewerPalette) private var palette

    /// One picker entry: a local engine, or a specific configured endpoint.
    private enum ServiceChoice: Hashable {
        case local(AppSettings.AIEngine)
        case onThisMac
        case endpoint(UUID?)
    }

    init(recording: Recording, initialOptions: ReprocessingOptions, usingPrevious: Bool,
         supportsCalendarReload: Bool, discardingRunID: UUID? = nil,
         dismissAction: (() -> Void)?) {
        self.recording = recording
        self.usingPrevious = usingPrevious
        self.supportsCalendarReload = supportsCalendarReload
        self.discardingRunID = discardingRunID
        self.dismissAction = dismissAction
        _options = State(initialValue: initialOptions)
    }

    private let languages = ["en", "nl", "de", "fr", "es", "it", "pt", "ja", "zh", "ko", "ru", "ar", "hi", "pl", "tr", "uk", "sv", "da", "no"]
    private var languageCodes: [String] {
        languages.contains(options.spokenLanguage) || options.spokenLanguage.isEmpty
            ? languages : languages + [options.spokenLanguage]
    }
    private var whisperModels: [String] {
        discoveredWhisperModels.isEmpty ? WhisperModelInfo.fallbackModelNames : discoveredWhisperModels
    }
    private var validationError: String? {
        if options.requiresAnalysis, case .custom(let code) = options.outputLanguage,
           code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter an AI output language code.")
        }
        do { try options.validate(); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelWindowHeader(
                title: options.operation.title,
                subtitle: recording.generatedTitle ?? recording.meetingTitleDraft,
                detail: usingPrevious ? String(localized: "Using previous attempt settings") : String(localized: "Using current defaults")
            )
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)
            MenuPanelHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if options.requiresTranscription { transcriptionControls }
                    if options.requiresAnalysis { analysisControls }
                    if options.operation == .speakers {
                        PanelCard(title: String(localized: "Speakers")) {
                            PanelNote(String(localized: "Detect speakers on-device using the original audio. Transcript words and timings are preserved; existing speaker assignments and names are replaced."))
                        }
                    }
                    destinationDisclosure
                    PanelNote(String(localized: "Current results stay readable while processing; editing is temporarily paused. Successful results replace the current set, with one previous set available to restore. Changes apply only to this attempt."))
                    if discardingRunID != nil {
                        PanelNote(String(localized: "Start also discards this recording's unfinished run in Queue & Recovery. Its saved progress can't be resumed afterwards."), tone: .warning)
                    }
                    if let message = error ?? validationError {
                        PanelNote(message, tone: .danger).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            MenuPanelHairline()
            HStack(spacing: 8) {
                if isStarting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, fillsWidth: false))
                    .disabled(isStarting)
                Button(appState.processingJob == nil ? "Start" : "Add to queue") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 30, fontSize: 12, fillsWidth: false))
                    .disabled(isStarting || validationError != nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 530)
        .panelWindowChrome()
        .interactiveDismissDisabled(isStarting)
        .sheet(isPresented: $showWhisperComparison) {
            TranscriptionModelPicker(modelIDs: whisperModels, selectedID: LocalTranscriptionChoice.id(
                engine: options.engine, whisper: options.whisperModelName, parakeet: options.parakeetModelVariant),
                language: options.spokenLanguage, identifySpeakers: options.diarizationEnabled) {
                    let engine = LocalTranscriptionChoice.engine($0)
                    if engine == .localWhisper { options.whisperModelName = $0 }
                    if let variant = LocalTranscriptionChoice.parakeetVariant($0) {
                        options.parakeetModelVariant = variant
                    }
                    options.engine = engine
                }
        }
        .task {
            discoveredWhisperModels = await manager.fetchAvailableWhisperModels()
        }
    }

    private func close() {
        if let dismissAction { dismissAction() }
        else { dismiss() }
    }

    @ViewBuilder private var transcriptionControls: some View {
        PanelCard(title: String(localized: "Transcription")) {
            if options.engine == .appleSpeech {
                AppleSpeechLanguagePicker(selection: $options.spokenLanguage, title: String(localized: "Spoken language"))
            } else {
                PanelRow(label: String(localized: "Spoken language")) {
                    Picker("Spoken language", selection: $options.spokenLanguage) {
                        Text(options.engine == .appleSpeech ? "Automatic (system language)" : "Automatic detection").tag("")
                        ForEach(languageCodes, id: \.self) { code in
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            PanelRow(label: String(localized: "Transcription")) {
                Picker("Transcription", selection: transcriptionChoice) {
                    Text("On this Mac").tag(ServiceChoice.onThisMac)
                    endpointSection(String(localized: "Remote services"), settings.transcriptionEndpoints,
                                    isSelected: options.engine == .remoteEndpoint, saved: options.transcriptionEndpoint)
                }
                .labelsHidden().fixedSize()
            }
            switch options.engine {
            case .localWhisper:
                PanelRow(label: String(localized: "Whisper model")) { Text(WhisperModelInfo.parse(options.whisperModelName).displayName) }
                PanelNote(String(localized: "Models download on first use."))
            case .parakeetLocal:
                PanelRow(label: String(localized: "Parakeet model")) { Text(ParakeetModelInfo.find(options.parakeetModelVariant).displayName) }
                PanelNote(String(localized: "Parakeet detects language automatically. v2 supports English; v3 supports 25 European languages. The spoken language selection does not force Parakeet decoding."))
            case .remoteEndpoint:
                if options.transcriptionEndpoint == nil {
                    PanelNote(String(localized: "No remote transcription service is configured. Add one in Settings → Transcription."))
                }
            case .appleSpeech:
                PanelNote(String(localized: "Uses Apple's speech model for the selected language."))
            }
            if options.engine != .remoteEndpoint {
                Button("Change model…") { showWhisperComparison = true }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 26, fontSize: 11, fillsWidth: false))
            }
            MenuPanelHairline()
            PanelRow(label: String(localized: "Detect speakers")) {
                Toggle("Detect speakers", isOn: $options.diarizationEnabled).labelsHidden().controlSize(.mini)
            }
            PanelRow(label: String(localized: "Regenerate AI analysis")) {
                Toggle("Regenerate AI analysis", isOn: $options.regenerateAI).labelsHidden().controlSize(.mini)
            }
            if !options.regenerateAI {
                PanelNote(String(localized: "Existing analysis will be kept and marked as based on the previous transcript."))
            }
        }
    }

    private var outputLanguageSelection: Binding<String> {
        Binding(get: {
            switch options.outputLanguage {
            case .matchInput: "match"
            case .english: "en"
            case .dutch: "nl"
            case .custom: "custom"
            }
        }, set: { value in
            switch value {
            case "en": options.outputLanguage = .english
            case "nl": options.outputLanguage = .dutch
            case "custom": options.outputLanguage = .custom("")
            default: options.outputLanguage = .matchInput
            }
        })
    }

    private var analysisControls: some View {
        PanelCard(title: String(localized: "AI analysis")) {
            PanelRow(label: String(localized: "AI engine")) {
                Picker("AI engine", selection: analysisChoice) {
                    ForEach(AppSettings.AIEngine.allCases.filter { $0 != .remoteEndpoint }, id: \.self) { engine in
                        Text(engine.displayName).tag(ServiceChoice.local(engine))
                    }
                    endpointSection(String(localized: "Remote endpoints"), settings.aiEndpoints,
                                    isSelected: options.aiEngine == .remoteEndpoint, saved: options.aiEndpoint)
                }
                .labelsHidden().fixedSize()
            }
            if options.aiEngine == .remoteEndpoint && options.aiEndpoint == nil {
                PanelNote(String(localized: "No remote AI endpoint is configured. Add one in Settings → AI analysis."))
            }
            if supportsCalendarReload {
                PanelRow(label: String(localized: "Refresh selected calendar attendees")) {
                    Toggle("Refresh selected calendar attendees", isOn: Binding(
                        get: { options.loadCalendarParticipants == true },
                        set: { options.loadCalendarParticipants = $0 }))
                    .labelsHidden().controlSize(.mini)
                }
            }
            PanelRow(label: String(localized: "AI output language")) {
                Picker("AI output language", selection: outputLanguageSelection) {
                    Text("Match transcript").tag("match")
                    Text("English").tag("en")
                    Text("Dutch").tag("nl")
                    Text("Custom language code").tag("custom")
                }
                .labelsHidden().fixedSize()
            }
            if case .custom(let code) = options.outputLanguage {
                TextField("Language code", text: Binding(get: { code }, set: { options.outputLanguage = .custom($0) }))
                    .panelTextField()
            }
        }
    }

    private var transcriptionChoice: Binding<ServiceChoice> {
        Binding(get: {
            options.engine == .remoteEndpoint ? .endpoint(options.transcriptionEndpoint?.id) : .onThisMac
        }, set: { choice in
            switch choice {
            case .endpoint(let id):
                if let endpoint = settings.transcriptionEndpoints.first(where: { $0.id == id }) {
                    options.selectTranscriptionEndpoint(endpoint)
                }
            default:
                guard options.engine == .remoteEndpoint else { return }
                let preferred = settings.effectiveTranscriptionEngine
                options.engine = preferred == .remoteEndpoint ? .localWhisper : preferred
            }
        })
    }

    private var analysisChoice: Binding<ServiceChoice> {
        Binding(get: {
            options.aiEngine == .remoteEndpoint ? .endpoint(options.aiEndpoint?.id) : .local(options.aiEngine)
        }, set: { choice in
            switch choice {
            case .local(let engine):
                options.selectAnalysis(engine: engine, settings: settings)
            case .endpoint(let id):
                if let endpoint = settings.aiEndpoints.first(where: { $0.id == id }) {
                    options.selectAnalysis(engine: .remoteEndpoint, endpoint: endpoint, settings: settings)
                }
            case .onThisMac:
                break
            }
        })
    }

    /// Lists every configured endpoint, plus the attempt's own endpoint when it
    /// is no longer configured, so the picker never shows a blank selection.
    @ViewBuilder
    private func endpointSection(_ title: String, _ endpoints: [Endpoint], isSelected: Bool,
                                 saved: Endpoint?) -> some View {
        if !endpoints.isEmpty || isSelected {
            Section(title) {
                ForEach(endpoints) { endpoint in
                    Text("\(endpoint.name) · \(endpoint.modelName)").tag(ServiceChoice.endpoint(endpoint.id))
                }
                if isSelected {
                    if let saved {
                        if !endpoints.contains(where: { $0.id == saved.id }) {
                            Text("\(saved.name) (unavailable)").tag(ServiceChoice.endpoint(saved.id))
                        }
                    } else {
                        Text("No endpoint configured").tag(ServiceChoice.endpoint(nil))
                    }
                }
            }
        }
    }

    private var destinationDisclosure: some View {
        PanelCard(title: String(localized: "Processing destinations")) {
            if options.requiresTranscription && options.engine == .remoteEndpoint {
                PanelRow(label: String(localized: "Audio")) { Text(destination(options.transcriptionEndpoint)) }
            }
            if options.requiresAnalysis && options.aiEngine == .remoteEndpoint {
                PanelRow(label: String(localized: "Transcript")) { Text(destination(options.aiEndpoint)) }
            }
            if options.requiresAnalysis && options.aiEngine == .localCLI {
                PanelNote(String(localized: "Transcript is passed to your configured Local CLI command, which may use an external service."))
            }
            if options.requiresTranscription && !options.vocabulary.isEmpty && options.spellingEngine == .remoteEndpoint {
                PanelRow(label: String(localized: "Vocabulary correction")) { Text(destination(options.aiEndpoint)) }
            }
            PanelNote(String(localized: "Speaker detection runs on this Mac. Integration delivery and exports are separate actions."))
        }
    }

    private func destination(_ endpoint: Endpoint?) -> String {
        guard let endpoint else { return String(localized: "No endpoint configured") }
        let host = URL(string: endpoint.baseURL)?.host ?? String(localized: "configured endpoint")
        return "\(endpoint.name) (\(host))"
    }

    private func start() {
        isStarting = true
        error = nil
        let audioURL = recording.finalizedAudioURL ?? recording.fileURL
        if options.requiresTranscription || options.operation == .speakers {
            let launchWindow = NSApp.keyWindow
            let parent = dismissAction == nil ? (launchWindow?.sheetParent ?? launchWindow) : nil
            SpeakerReviewWindowController.shared.preparePresentation(for: audioURL, parent: parent)
        }
        Task {
            do {
                try options.validate()
                if let discardingRunID { try await manager.discardUnfinishedRun(discardingRunID) }
                try await manager.startReprocessing(for: recording, options: options)
                close()
            } catch {
                SpeakerReviewWindowController.shared.preparePresentation(for: audioURL, parent: nil)
                self.error = error.localizedDescription
            }
            isStarting = false
        }
    }
}
