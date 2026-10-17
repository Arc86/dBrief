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

    /// Ratings and requirements for one picker id: the single source for the model card,
    /// the picker and `ModelSuggestions`. Nil for ids outside the catalog.
    static func profile(_ id: String, modernApple: Bool = false) -> LocalModelProfile? {
        if id == apple {
            return LocalModelProfile(speed: modernApple ? 4 : nil, accuracy: modernApple ? 4 : nil,
                                     languages: .system, runtimeGiB: nil, downloadMB: nil, minimumMacOSMajor: 14)
        }
        if id.hasPrefix(parakeetPrefix) {
            // Exact lookup: `ParakeetModelInfo.find` resolves an OS-unsupported variant to v3.
            let variantID = String(id.dropFirst(parakeetPrefix.count))
            guard let model = ParakeetModelInfo.variants.first(where: { $0.id == variantID }) else { return nil }
            return LocalModelProfile(
                speed: model.id == "redux" ? 4 : 5,
                // Ultra: FluidAudio reports fewer errors than v3 on all 24 FLEURS languages and LibriSpeech.
                accuracy: model.id == "ultra" ? 5 : 4,
                languages: model.isEnglishOnly ? .englishOnly : .codes(ParakeetModelInfo.languageCodes),
                runtimeGiB: Double(model.estimatedMemoryMB) / 1024, downloadMB: nil,
                minimumMacOSMajor: model.minimumMacOSMajor,
                // FluidAudio documents Phonon-2 as the fastest v3-family encoder on the Neural Engine.
                speedTieBreak: model.id == "phonon2" ? 1 : 0)
        }
        guard let entry = WhisperModelCatalog.entries[id] else { return nil }
        return LocalModelProfile(speed: entry.speed, accuracy: entry.accuracy,
                                 languages: entry.englishOnly ? .englishOnly : .all,
                                 runtimeGiB: entry.runtimeGiB, downloadMB: WhisperModelInfo.parse(id).quantizedSizeMB,
                                 minimumMacOSMajor: 14)
    }

    /// Compact name for tiles, list rows and the "Use …" button.
    static func shortTitle(_ id: String) -> String {
        if id == apple { return "Apple Speech" }
        if let variant = parakeetVariant(id) {
            switch variant {
            case "v2": return "Parakeet v2"
            case "ultra": return "Parakeet Ultra"
            case "redux": return "Parakeet Redux"
            case "phonon2": return "Parakeet Phonon-2"
            default: return "Parakeet v3"
            }
        }
        if id == WhisperModelInfo.recommendedModelID { return "Whisper Turbo" }
        return WhisperModelInfo.parse(id).displayName
    }
}

struct LocalModelProfile: Equatable {
    enum Languages: Equatable { case all, codes(Set<String>), englishOnly, system }

    let speed: Int?
    let accuracy: Int?
    let languages: Languages
    let runtimeGiB: Double?
    let downloadMB: Int?
    let minimumMacOSMajor: Int
    var speedTieBreak = 0

    /// "nl-NL" / "pt_BR" / "EN" → "nl" / "pt" / "en"; "" stays "" (auto-detect).
    static func baseCode(_ language: String) -> String {
        language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    }

    /// Whether this model can transcribe `language`. Auto-detect ("") excludes English-only models.
    func covers(language: String) -> Bool {
        let code = Self.baseCode(language)
        switch languages {
        case .all, .system: return true
        case .englishOnly: return code == "en"
        case .codes(let codes): return code.isEmpty || codes.contains(code)
        }
    }

    var languageLabel: String {
        switch languages {
        case .all: "99 languages"
        case .codes(let codes): "\(codes.count) European languages"
        case .englishOnly: "English only"
        case .system: "System-supported languages"
        }
    }
}
