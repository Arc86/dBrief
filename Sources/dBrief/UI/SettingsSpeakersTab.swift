import SwiftUI

/// Which transcription engines can label speakers. Apple Speech has no diarization path
/// (RecordingManager never passes `diarize` to it); remote only Deepgram and ElevenLabs.
enum SpeakerIdentificationSupport {
    static func isSupported(engine: AppSettings.TranscriptionEngine, remoteProvider: Endpoint.Provider?) -> Bool {
        switch engine {
        case .localWhisper, .parakeetLocal: true
        case .appleSpeech: false
        case .remoteEndpoint: remoteProvider == .deepgram || remoteProvider == .elevenLabs
        }
    }
}

/// Speakers: whether dBrief tells voices apart, how recognised voices are applied,
/// and the on-device library of people it has learned.
struct SettingsSpeakersTab: View {
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var settings = appSettings
        let engine = appSettings.effectiveTranscriptionEngine
        let supported = SpeakerIdentificationSupport.isSupported(
            engine: engine, remoteProvider: appSettings.effectiveDefaultTranscriptionEndpoint?.provider)

        SettingsPageScaffold(page: .speakers) {
            SettingsCard("Identification", section: .speakerIdentification) {
                SettingsRow(verbatim: "Identify speakers",
                            caption: supported
                                ? "Labels who said what. Adds processing time and about 500 MB of memory."
                                : "Not available with \(engine.displayName). Your choice is kept for other engines.") {
                    Toggle("Identify speakers", isOn: $settings.diarizationEnabled)
                        .disabled(!supported)
                }
                if appSettings.diarizationEnabled && supported {
                    SettingsRow(verbatim: "When a voice is recognised", caption: settings.speakerIdMode.shortDescription) {
                        Picker("When a voice is recognised", selection: $settings.speakerIdMode) {
                            ForEach(AppSettings.SpeakerIdMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            SettingsCard("Known people", description: "Voiceprints stay on this Mac and are never uploaded",
                         section: .speakerLibrary) {
                SettingsVoiceLibraryTab()
            }
        }
    }
}
