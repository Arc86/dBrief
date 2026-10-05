import SwiftUI
import dBriefWire

/// Kept separate so showing live preferences never starts model discovery or loading.
struct LiveTranscriptionSettingsSection: View {
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var settings = appSettings
        Group {
            Toggle("Transcribe live while recording", isOn: $settings.liveTranscriptionEnabled)
                .accessibilityIdentifier("live-transcription-enabled")
            Text("Your microphone and system audio keep separate source labels. The final transcript uses its own engine and language.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Live engine", selection: Binding(get: { settings.liveTranscriptionEngine }, set: { engine in
                if engine == settings.liveTranscriptionEngine || LiveTranscriptionCatalogue.engines.contains(where: { $0.engine == engine && $0.canSelect }) {
                    settings.liveTranscriptionEngine = engine
                }
            })) {
                ForEach(LiveTranscriptionCatalogue.engines, id: \.engine) { row in
                    Text(row.title).tag(row.engine).disabled(!row.canSelect)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("live-transcription-engine")

            if settings.liveTranscriptionEngine == .appleSpeech {
                AppleSpeechLanguagePicker(selection: $settings.appleLiveLanguage, title: "Live audio language")
            } else {
                Text("Live transcript unavailable while Nemotron validation is pending. Audio recording and the final transcript can continue.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Candidate language", selection: $settings.nemotronLiveLanguage) {
                    Text("Automatic").tag(LiveASRConfiguration.Language.auto)
                    Text("English").tag(LiveASRConfiguration.Language.en)
                    Text("Dutch").tag(LiveASRConfiguration.Language.nl)
                }.pickerStyle(.menu)
                Picker("Model input target", selection: $settings.nemotronLiveChunkMs) {
                    Text("560 ms").tag(560)
                    Text("1120 ms").tag(1120)
                    Text("2240 ms").tag(2240)
                }.pickerStyle(.menu)
                Text("Candidate settings await validation. The input target does not promise caption latency.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Live speaker labels for system audio", isOn: Binding(get: { settings.liveSpeakerLabelsEnabled }, set: { requested in
                if LiveTranscriptionCatalogue.allowsLabelChange(current: settings.liveSpeakerLabelsEnabled, requested: requested) {
                    settings.liveSpeakerLabelsEnabled = requested
                }
            }))
            .disabled(!LiveTranscriptionCatalogue.canEnableSpeakerLabels && !settings.liveSpeakerLabelsEnabled)
            .accessibilityIdentifier("live-speaker-labels")
            Text("Optional anonymous labels require a validated Nemotron configuration. Microphone and system labels identify capture sources.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changes apply the next time live transcription starts.")
                .font(.caption).foregroundStyle(.secondary)

            DisclosureGroup("Live availability") {
                ForEach(LiveTranscriptionCatalogue.engines, id: \.engine) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).font(.caption.weight(.semibold))
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
