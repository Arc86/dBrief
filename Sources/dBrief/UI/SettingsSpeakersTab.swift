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
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        @Bindable var settings = appSettings
        let engine = appSettings.effectiveTranscriptionEngine
        let supported = SpeakerIdentificationSupport.isSupported(
            engine: engine, remoteProvider: appSettings.effectiveDefaultTranscriptionEndpoint?.provider)

        SettingsPageScaffold(page: .speakers, layout: .fill) {
            // One slim row, so the library below gets the page's height.
            SettingsCard(section: .speakerIdentification) {
                SettingsStackedRow {
                    HStack(spacing: 12) {
                        Toggle("Identify speakers", isOn: $settings.diarizationEnabled)
                            .labelsHidden()
                            .disabled(!supported)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Identify speakers")
                                .uiFont(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.heading.color)
                            Text(supported
                                 ? "Labels who said what. Adds processing time and about 500 MB of memory."
                                 : "Not available with \(engine.displayName). Your choice is kept for other engines.")
                                .uiFont(.system(size: 11.5))
                                .foregroundStyle(palette.secondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if appSettings.diarizationEnabled && supported {
                            Text("When a voice is recognised")
                                .uiFont(.system(size: 12))
                                .foregroundStyle(palette.secondary.color)
                            Picker("When a voice is recognised", selection: $settings.speakerIdMode) {
                                ForEach(AppSettings.SpeakerIdMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .help(settings.speakerIdMode.shortDescription)
                        }
                    }
                }
            }

            SettingsCard("Known people", description: "Voiceprints stay on this Mac and are never uploaded",
                         section: .speakerLibrary) {
                SettingsVoiceLibraryTab()
            }
            .frame(maxHeight: .infinity)
        }
    }
}
