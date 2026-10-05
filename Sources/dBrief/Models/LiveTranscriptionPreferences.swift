import Foundation
import dBriefWire

/// A capture request never consults changing live or final settings after admission.
struct LiveTranscriptionPreferences: Sendable, Equatable {
    let enabled: Bool
    let engine: LiveTranscriptionEngine
    let appleLanguage: String
    let nativeLanguage: LiveASRConfiguration.Language
    let chunkMs: Int
    let speakerLabels: Bool
    var language: String { engine == .nemotron ? nativeLanguage.rawValue : appleLanguage }

    @MainActor static func migrateAppleLanguage(in defaults: UserDefaults, legacyEffectiveLanguage: String) -> String {
        if let saved = defaults.string(forKey: AppSettings.Keys.appleLiveLanguage) { return saved }
        defaults.set(legacyEffectiveLanguage, forKey: AppSettings.Keys.appleLiveLanguage)
        return legacyEffectiveLanguage
    }
}

extension AppSettings {
    var liveTranscriptionPreferences: LiveTranscriptionPreferences {
        .init(enabled: liveTranscriptionEnabled, engine: liveTranscriptionEngine,
              appleLanguage: appleLiveLanguage, nativeLanguage: nemotronLiveLanguage,
              chunkMs: nemotronLiveChunkMs,
              speakerLabels: liveTranscriptionEnabled && liveTranscriptionEngine == .nemotron && liveSpeakerLabelsEnabled)
    }
}

/// Selection policy only. Apple availability is checked by its actual runtime;
/// unqualified native candidates never gain a profile or loader from this catalogue.
enum LiveTranscriptionCatalogue {
    enum Availability: Sendable, Equatable { case managedAtStart, validationPending }
    struct Engine: Sendable, Equatable {
        let engine: LiveTranscriptionEngine
        let title: String
        let detail: String
        let availability: Availability
        let canSelect: Bool
    }
    static let engines: [Engine] = [
        .init(engine: .appleSpeech, title: "Apple Speech", detail: "On-device speech managed by macOS. Language and device availability are checked when it starts.",
              availability: .managedAtStart, canSelect: true),
        .init(engine: .nemotron, title: "Nemotron — validation pending", detail: "Live Nemotron is awaiting compatibility, timing and combined-load validation. Recording and the final transcript can continue.",
              availability: .validationPending, canSelect: false)
    ]
    static let canEnableSpeakerLabels = false
    static func allowsLabelChange(current: Bool, requested: Bool) -> Bool {
        !requested || current || canEnableSpeakerLabels
    }
}
