import SwiftUI
import dBriefWire

/// Attempt settings are value copies; editing this sheet never changes a profile.
struct ReprocessingSheet: View {
    let recording: Recording
    let operation: ReprocessingOperation
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var options: ReprocessingOptions?
    @State private var usingPrevious = false

    var body: some View {
        Group {
            if let options {
                ReprocessingEditor(recording: recording, initialOptions: options, usingPrevious: usingPrevious)
            } else {
                VStack(spacing: 16) {
                    ProgressView("Loading settings…")
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(32)
            }
        }
        .task {
            let previous = await manager.lastReprocessingOptions(for: recording)
            guard !Task.isCancelled else { return }
            usingPrevious = previous != nil
            var value = previous ?? ReprocessingOptions(settings: settings, operation: operation)
            value.operation = operation
            options = value
        }
    }
}

private struct ReprocessingEditor: View {
    let recording: Recording
    let usingPrevious: Bool
    @State private var options: ReprocessingOptions
    @State private var isStarting = false
    @State private var error: String?
    @Environment(RecordingManager.self) private var manager
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    init(recording: Recording, initialOptions: ReprocessingOptions, usingPrevious: Bool) {
        self.recording = recording
        self.usingPrevious = usingPrevious
        _options = State(initialValue: initialOptions)
    }

    private let languages = ["en", "nl", "de", "fr", "es", "it", "pt", "ja", "zh", "ko", "ru", "ar", "hi", "pl", "tr", "uk", "sv", "da", "no"]
    private var languageCodes: [String] {
        languages.contains(options.spokenLanguage) || options.spokenLanguage.isEmpty
            ? languages : languages + [options.spokenLanguage]
    }
    private var whisperModels: [String] {
        Array(Set(WhisperModelInfo.fallbackModelNames + [options.whisperModelName])).sorted()
    }
    private var validationError: String? {
        if options.requiresAnalysis, case .custom(let code) = options.outputLanguage,
           code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an AI output language code."
        }
        do { try options.validate(); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(options.operation.title).font(.title2.weight(.semibold))
            Text(recording.generatedTitle ?? recording.meetingTitleDraft).lineLimit(2)
            Text(usingPrevious ? "Using previous attempt settings" : "Using current defaults")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                if options.requiresTranscription { transcriptionControls }
                if options.requiresAnalysis { analysisControls }
                if options.operation == .speakers {
                    Text("Detect speakers on-device using the original audio. Transcript words and timings are preserved; existing speaker assignments and names are replaced.")
                }
                destinationDisclosure
            }
            .formStyle(.grouped)
            .frame(minHeight: 160, maxHeight: 390)
            Text("Current results stay readable while processing; editing is temporarily paused. Successful results replace the current set, with one previous set available to restore. Changes apply only to this attempt.")
                .font(.callout).foregroundStyle(.secondary)
            if let message = error ?? validationError {
                Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isStarting)
                Button(appState.processingJob == nil ? "Start" : "Add to Queue") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isStarting || validationError != nil)
                if isStarting { ProgressView().controlSize(.small) }
            }
        }
        .padding(24)
        .frame(width: 530)
        .interactiveDismissDisabled(isStarting)
    }

    @ViewBuilder private var transcriptionControls: some View {
        Section("Transcription") {
            Picker("Spoken language", selection: $options.spokenLanguage) {
                Text(options.engine == .appleSpeech ? "Automatic (system language)" : "Automatic detection").tag("")
                ForEach(languageCodes, id: \.self) { code in
                    Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                }
            }
            Picker("Transcription engine", selection: $options.engine) {
                ForEach(AppSettings.TranscriptionEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            switch options.engine {
            case .localWhisper:
                Picker("Whisper model", selection: $options.whisperModelName) {
                    ForEach(whisperModels, id: \.self) { name in
                        Text(WhisperModelInfo.parse(name).displayName).tag(name)
                    }
                }
                Text("Models download on first use.").font(.caption).foregroundStyle(.secondary)
            case .parakeetLocal:
                Picker("Parakeet model", selection: $options.parakeetModelVariant) {
                    ForEach(ParakeetModelInfo.variants) { model in Text(model.displayName).tag(model.id) }
                }
                Text("Parakeet detects language automatically. v2 supports English; v3 supports 25 European languages. The spoken language selection does not force Parakeet decoding.")
                    .font(.caption).foregroundStyle(.secondary)
            case .remoteEndpoint:
                LabeledContent("Model", value: options.transcriptionEndpoint?.modelName ?? "No endpoint configured")
            case .appleSpeech:
                Text("Uses Apple's speech model for the selected language.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Detect speakers", isOn: $options.diarizationEnabled)
            Toggle("Regenerate AI analysis", isOn: $options.regenerateAI)
            if !options.regenerateAI {
                Text("Existing analysis will be kept and marked as based on the previous transcript.")
                    .font(.caption).foregroundStyle(.secondary)
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
        Section("AI analysis") {
            LabeledContent("AI engine", value: options.aiEngine.displayName)
            Picker("AI output language", selection: outputLanguageSelection) {
                Text("Match transcript").tag("match")
                Text("English").tag("en")
                Text("Dutch").tag("nl")
                Text("Custom language code").tag("custom")
            }
            if case .custom(let code) = options.outputLanguage {
                TextField("Language code", text: Binding(get: { code }, set: { options.outputLanguage = .custom($0) }))
            }
        }
    }

    private var destinationDisclosure: some View {
        Section("Processing destinations") {
            if options.requiresTranscription && options.engine == .remoteEndpoint {
                Text("Audio → \(destination(options.transcriptionEndpoint))")
            }
            if options.requiresAnalysis && options.aiEngine == .remoteEndpoint {
                Text("Transcript → \(destination(options.aiEndpoint))")
            }
            if options.requiresAnalysis && options.aiEngine == .localCLI {
                Text("Transcript is passed to your configured Local CLI command, which may use an external service.")
            }
            if options.requiresTranscription && !options.vocabulary.isEmpty && options.spellingEngine == .remoteEndpoint {
                Text("Transcript for vocabulary correction → \(destination(options.aiEndpoint))")
            }
            Text("Speaker detection runs on this Mac. Integration delivery and exports are separate actions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func destination(_ endpoint: Endpoint?) -> String {
        guard let endpoint else { return "No endpoint configured" }
        let host = URL(string: endpoint.baseURL)?.host ?? "configured endpoint"
        return "\(endpoint.name) (\(host))"
    }

    private func start() {
        isStarting = true
        error = nil
        Task {
            do {
                try options.validate()
                try await manager.startReprocessing(for: recording, options: options)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isStarting = false
        }
    }
}
