import Foundation
import dBriefWire

/// The three Quick pick tiles in the transcription model picker.
enum ModelIntent: Hashable {
    case fastest, recommended, mostAccurate

    var title: String {
        switch self {
        case .fastest: "Fastest"
        case .recommended: "Recommended"
        case .mostAccurate: "Most accurate"
        }
    }

    var symbol: String {
        switch self {
        case .fastest: "bolt.fill"
        case .recommended: "star.fill"
        case .mostAccurate: "scope"
        }
    }
}

struct ModelSuggestion: Equatable {
    let intent: ModelIntent
    let modelID: String
    let reason: String
}

/// Picks the Quick pick tiles from the spoken language, this Mac's RAM and macOS version.
/// Pure: no IO. Rules: docs/superpowers/specs/2026-10-10-model-picker-design.md.
enum ModelSuggestions {
    static let speakersGiB = 0.5
    static let maxRAMShare = 0.5

    /// English display name of the spoken language, or nil for auto-detect.
    static func languageName(_ language: String) -> String? {
        let code = LocalModelProfile.baseCode(language)
        guard !code.isEmpty else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private struct Candidate {
        let id: String
        let profile: LocalModelProfile
        let speed: Int
        let accuracy: Int
        let ram: Double
    }

    /// Up to three distinct picks in display order: fastest, recommended, most accurate.
    /// `language` is the spoken-language setting ("" = auto-detect). `available` is the picker's
    /// default list (curated Whisper ids + Parakeet/Apple ids), never every variant.
    static func picks(language: String, installedRAMGiB: Double, macOSMajor: Int, identifySpeakers: Bool,
                      available: [String], downloaded: Set<String> = [],
                      profile: (String) -> LocalModelProfile? = { LocalTranscriptionChoice.profile($0) })
        -> [ModelSuggestion] {
        let speakers = identifySpeakers ? speakersGiB : 0
        let code = LocalModelProfile.baseCode(language)
        let name = languageName(language)
        let eligible: [Candidate] = available.compactMap { id in
            guard id != LocalTranscriptionChoice.apple, let p = profile(id),
                  let speed = p.speed, let accuracy = p.accuracy, let ram = p.runtimeGiB,
                  p.minimumMacOSMajor <= macOSMajor, p.covers(language: language),
                  ram + speakers <= maxRAMShare * installedRAMGiB else { return nil }
            return Candidate(id: id, profile: p, speed: speed, accuracy: accuracy, ram: ram)
        }

        // `ranksAhead(a, b)` is true when a should win; `min(by:)` keeps the first of equals (catalog order).
        let byAccuracy: (Candidate, Candidate) -> Bool = { a, b in
            if a.accuracy != b.accuracy { return a.accuracy > b.accuracy }
            if a.speed != b.speed { return a.speed > b.speed }
            return a.ram < b.ram
        }
        let bySpeed: (Candidate, Candidate) -> Bool = { a, b in
            if a.speed != b.speed { return a.speed > b.speed }
            if a.accuracy != b.accuracy { return a.accuracy > b.accuracy }
            if code == "en" {
                let aEnglish = a.profile.languages == .englishOnly, bEnglish = b.profile.languages == .englishOnly
                if aEnglish != bEnglish { return aEnglish }
            }
            if a.profile.speedTieBreak != b.profile.speedTieBreak { return a.profile.speedTieBreak > b.profile.speedTieBreak }
            return a.ram < b.ram
        }
        var taken = Set<String>()
        func best(_ pool: [Candidate], _ ranksAhead: (Candidate, Candidate) -> Bool) -> Candidate? {
            pool.filter { !taken.contains($0.id) }.min(by: ranksAhead)
        }

        // 1. Recommended
        let recommended = eligible.first { $0.id == WhisperModelInfo.recommendedModelID } ?? best(eligible, byAccuracy)
        if let recommended { taken.insert(recommended.id) }

        // 2. Most accurate: fast models first; fall back to any model, but only if it beats Recommended.
        let floor = recommended?.accuracy ?? 0
        var mostAccurate: (Candidate, isFallback: Bool)?
        if let fast = best(eligible.filter { $0.speed >= 4 }, byAccuracy), fast.accuracy > floor {
            mostAccurate = (fast, false)
        } else if let any = best(eligible, byAccuracy), any.accuracy > floor {
            mostAccurate = (any, true)
        }
        if let mostAccurate { taken.insert(mostAccurate.0.id) }

        // 3. Fastest
        let fastest = best(eligible, bySpeed)

        var result: [ModelSuggestion] = []
        if let fastest {
            var reason = if case .codes = fastest.profile.languages, name == nil {
                "Quickest on Apple Silicon. Skip it for meetings in other languages."
            } else {
                "Quickest for \(name ?? "your meetings") on this Mac."
            }
            if fastest.accuracy <= 2 { reason += " Lowest accuracy; for quick drafts." }
            result.append(ModelSuggestion(intent: .fastest, modelID: fastest.id, reason: reason))
        }
        if let recommended {
            let reason = recommended.id == WhisperModelInfo.recommendedModelID
                ? "Best all-rounder: any language, light on memory." + (downloaded.contains(recommended.id) ? " Ready now." : "")
                : "Best fit for \(name ?? "your meetings") on this Mac."
            result.append(ModelSuggestion(intent: .recommended, modelID: recommended.id, reason: reason))
        }
        if case let (pick, isFallback)? = mostAccurate {
            let reason = if isFallback {
                "Slow. For recordings where every word matters."
            } else if let name {
                "Fewest errors for \(name) meetings."
            } else {
                "Fewest errors in \(pick.profile.languageLabel)."
            }
            result.append(ModelSuggestion(intent: .mostAccurate, modelID: pick.id, reason: reason))
        }
        return result
    }
}
