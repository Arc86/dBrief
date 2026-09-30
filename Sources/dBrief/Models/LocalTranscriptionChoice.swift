import Foundation
import dBriefWire

/// Picker identity is separate from stored engine-specific settings.
enum LocalTranscriptionChoice {
    static let apple = "apple-speech"
    private static let parakeetPrefix = "parakeet:"
    static func parakeet(_ variant: String) -> String { parakeetPrefix + variant }
    /// Multilingual Parakeet first, then Apple, then English-only Parakeet.
    static let extraIDs = ParakeetModelInfo.available.filter { !$0.isEnglishOnly }.map { parakeet($0.id) }
        + [apple] + ParakeetModelInfo.available.filter(\.isEnglishOnly).map { parakeet($0.id) }

    /// The Parakeet variant a picker id selects (stale ids resolve to the default), or nil for other engines.
    static func parakeetVariant(_ id: String) -> String? {
        guard id.hasPrefix(parakeetPrefix) else { return nil }
        return ParakeetModelInfo.find(String(id.dropFirst(parakeetPrefix.count))).id
    }

    static func runtimeGiB(_ id: String) -> Double? {
        if let variant = parakeetVariant(id) {
            return Double(ParakeetModelInfo.find(variant).estimatedMemoryMB) / 1024
        }
        return WhisperModelCatalog.entries[id]?.runtimeGiB
    }

    static func engine(_ id: String) -> AppSettings.TranscriptionEngine {
        if id == apple { return .appleSpeech }
        if parakeetVariant(id) != nil { return .parakeetLocal }
        return .localWhisper
    }

    static func id(engine: AppSettings.TranscriptionEngine, whisper: String, parakeet: String) -> String {
        switch engine {
        case .appleSpeech: apple
        case .parakeetLocal: Self.parakeet(ParakeetModelInfo.find(parakeet).id)
        default: whisper
        }
    }

    static func title(_ id: String) -> String {
        if id == apple { return "Apple Speech" }
        if let variant = parakeetVariant(id) { return ParakeetModelInfo.find(variant).displayName }
        return WhisperModelInfo.parse(id).displayName
    }
}
