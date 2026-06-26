import SwiftUI
import dBriefWire

/// Settings for the spoken-summary (text-to-speech) feature: voice engine, voice,
/// language, an audition preview, and the prompts that shape the spoken script.
/// Split out of the AI Analysis tab so analysis and read-aloud config are separate.
struct SettingsSpokenVoiceTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var voicePreview = VoicePreviewPlayer()
    @State private var expandedPrompt: String?

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Spoken Voice") {
                Picker("Voice engine", selection: $settings.ttsEngine) {
                    ForEach(TTSEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                Text(settings.ttsEngine.shortDescription)
                    .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Voice", selection: $settings.ttsVoice) {
                        ForEach(TTSVoice.allCases, id: \.self) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(settings.ttsVoice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Language", selection: $settings.ttsLanguage) {
                        ForEach(TTSLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Each voice sounds best in its native language. Choose the language your summary is written in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    voicePreviewRow
                    promptRow(label: "Voice Style", key: "ttsVoiceStyle", text: $settings.ttsDeliveryInstruction, defaultText: AppSettings.defaultTTSDeliveryInstruction)
                case .kokoro:
                    Picker("Voice", selection: $settings.ttsKokoroVoice) {
                        ForEach(KokoroVoice.allCases, id: \.self) { voice in
                            Text("\(voice.displayName) · \(voice.language)").tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Kokoro is in beta and speaks English. The chosen voice sets the language — there's no separate language or style control.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    voicePreviewRow
                }
            }
                .listRowBackground(Color.clear)
            if appSettings.powerUserMode {
                Section("Prompt") {
                    promptRow(label: "Spoken Summary", key: "spokenSummary", text: $settings.spokenSummaryPrompt, defaultText: AppSettings.defaultSpokenSummaryPrompt)
                }
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
    }

    /// A short sample sentence in the language the preview will be spoken in.
    /// Qwen3 uses the selected output language; Kokoro speaks English.
    private var previewSampleText: String {
        switch appSettings.ttsEngine {
        case .qwen3:
            return appSettings.ttsLanguage.sampleText
        case .kokoro:
            return TTSLanguage.english.sampleText
        }
    }

    /// Audition the selected voice/language/model/style with a short sample.
    @ViewBuilder
    private var voicePreviewRow: some View {
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
                if case let .failed(message) = voicePreview.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .synthesizing:
                ProgressView().controlSize(.small)
                Text("Synthesizing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onDisappear { voicePreview.stop() }
    }

    private func promptRow(label: String, key: String, text: Binding<String>, defaultText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedPrompt = expandedPrompt == key ? nil : key
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expandedPrompt == key ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 10)
                        Text(label)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if text.wrappedValue != defaultText {
                    Button("Reset") {
                        text.wrappedValue = defaultText
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if expandedPrompt == key {
                NativeTextView(text: text)
                    .frame(height: 80)
            }
        }
    }
}
