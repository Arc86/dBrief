import SwiftUI
import dBriefWire

/// Settings for the spoken-summary (text-to-speech) feature: voice engine, voice,
/// language, an audition preview, and the prompts that shape the spoken script.
/// Split out of the AI Analysis tab so analysis and read-aloud config are separate.
struct SettingsSpokenVoiceTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.settingsSearchRevealAdvanced) private var searchAdvanced
    @Environment(\.settingsSearchRequest) private var searchRequest
    @Environment(RecordingManager.self) private var recordingManager
    @State private var voicePreview = VoicePreviewPlayer()

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Spoken Voice", settingsSearch: .spokenVoice) {
                Picker("Voice engine", selection: $settings.ttsEngine) {
                    ForEach(TTSEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                Text(settings.ttsEngine.shortDescription)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)

                Picker("Language", selection: languageBinding) {
                    ForEach(settings.ttsEngine.supportedLanguages, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                Text(languageCaption)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)

                switch settings.ttsEngine {
                case .qwen3:
                    Picker("Voice model", selection: $settings.ttsModelSize) {
                        ForEach(TTSModelSize.allCases, id: \.self) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("1.7B sounds the most natural and follows the voice style below. 0.6B is lighter on memory (better for 16 GB Macs) but ignores the style instruction.")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Voice", selection: $settings.ttsVoice) {
                        ForEach(TTSVoice.allCases, id: \.self) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(settings.ttsVoice.detail)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                    voicePreviewRow
                    if settings.ttsModelSize.supportsVoiceInstruction {
                        PromptSettingsRow(kind: .voiceStyle)
                    } else {
                        Text("Voice style requires the 1.7B model. Your instruction is kept for when you switch back.")
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .kokoro:
                    Picker("Voice", selection: kokoroVoiceBinding) {
                        ForEach(KokoroVoice.voices(for: settings.spokenSummaryLanguage), id: \.self) { voice in
                            Text("\(voice.displayName) · \(voice.detail)").tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(kokoroDownloadNote)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                    voicePreviewRow
                }
            }
                .listRowBackground(Color.clear)
            if appSettings.powerUserMode || searchAdvanced {
                Section("Prompt", settingsSearch: .spokenPrompt) {
                    PromptSettingsRow(kind: .spokenSummary)
                }
                    .listRowBackground(Color.clear)
            }
        }
        .settingsFormStyle()
    }

    /// Shows the language in effect; picking one also moves Kokoro to a voice that speaks it.
    private var languageBinding: Binding<TTSLanguage> {
        Binding(get: { appSettings.spokenSummaryLanguage }, set: { language in
            appSettings.ttsLanguage = language
            appSettings.ttsKokoroVoice = KokoroVoice.resolved(appSettings.ttsKokoroVoice, for: language)
        })
    }

    private var kokoroVoiceBinding: Binding<KokoroVoice> {
        Binding(get: { appSettings.effectiveKokoroVoice }, set: { appSettings.ttsKokoroVoice = $0 })
    }

    private var languageCaption: String {
        let chosen = appSettings.ttsLanguage
        if chosen != appSettings.spokenSummaryLanguage {
            return "\(chosen.displayName) isn't available with \(appSettings.ttsEngine.displayName), so English is used."
        }
        return "The summary is written and spoken in this language."
    }

    private var kokoroDownloadNote: String {
        switch appSettings.spokenSummaryLanguage {
        case .japanese: "Japanese uses its own voice model (about 217 MB), downloaded on first use, then works offline."
        case .english: "English voices download on first use (about 510 KB each), then work offline. British voices currently use US pronunciation rules."
        default: "Voices download on first use, then work offline."
        }
    }

    /// A short sample sentence in the language the summary will be spoken in.
    private var previewSampleText: String { appSettings.spokenSummaryLanguage.sampleText }

    /// Audition the selected voice/language/model/style with a short sample.
    @ViewBuilder
    private var voicePreviewRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                switch voicePreview.state {
                case .idle, .failed:
                    Button {
                        let tts = appSettings.ttsSynthesisParams
                        voicePreview.preview(
                            text: previewSampleText,
                            engine: tts.engine,
                            voice: tts.voice,
                            language: tts.language,
                            instruction: tts.instruction,
                            model: tts.model,
                            plugin: recordingManager.localPlugin
                        )
                    } label: {
                        Label("Preview voice", systemImage: "play.circle")
                    }
                case .playing:
                    Button(role: .cancel) {
                        voicePreview.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                case .preparingVoice(let progress):
                    ProgressView().controlSize(.small)
                    Text(progress != nil ? "Preparing voice… \(Int((progress ?? 0) * 100))%" : "Preparing voice…")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                case .synthesizing:
                    ProgressView().controlSize(.small)
                    Text("Synthesizing…")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if case let .failed(message) = voicePreview.state {
                SettingsErrorDetails(summary: "Voice preview failed", error: message)
            }
        }
        .onDisappear { voicePreview.stop() }
    }

}
