import Foundation
import dBriefWire

/// Picker identity is separate from stored engine-specific settings.
enum LocalTranscriptionChoice {
    static let apple = "apple-speech"
    static let parakeetV2 = "parakeet:v2"
    static let parakeetV3 = "parakeet:v3"
    static let extraIDs = [parakeetV3, apple, parakeetV2]

    static func runtimeGiB(_ id: String) -> Double? {
        if id == parakeetV2 || id == parakeetV3 {
            return Double(ParakeetModelInfo.find(id == parakeetV2 ? "v2" : "v3").estimatedMemoryMB) / 1024
        }
        return WhisperModelCatalog.entries[id]?.runtimeGiB
    }

    static func engine(_ id: String) -> AppSettings.TranscriptionEngine {
        if id == apple { return .appleSpeech }
        if id == parakeetV2 || id == parakeetV3 { return .parakeetLocal }
        return .localWhisper
    }

    static func id(engine: AppSettings.TranscriptionEngine, whisper: String, parakeet: String) -> String {
        switch engine {
        case .appleSpeech: apple
        case .parakeetLocal: parakeet == "v2" ? parakeetV2 : parakeetV3
        default: whisper
        }
    }

    static func title(_ id: String) -> String {
        switch id {
        case apple: "Apple Speech"
        case parakeetV2: ParakeetModelInfo.find("v2").displayName
        case parakeetV3: ParakeetModelInfo.find("v3").displayName
        default: WhisperModelInfo.parse(id).displayName
        }
    }
}
