import Foundation

/// Product allowlist from macOS Live Captions, verified 2026-09-13.
/// Keep separate from Apple's locale lookup, which can advertise unavailable assets.
enum AppleSpeechLanguages {
    struct Choice: Identifiable, Sendable {
        let id: String
        let name: String
    }
    static let choices: [Choice] = [
        .init(id: "en-AU", name: "English (Australia)"),
        .init(id: "en-CA", name: "English (Canada)"),
        .init(id: "en-IN", name: "English (India)"),
        .init(id: "en-SG", name: "English (Singapore)"),
        .init(id: "en-GB", name: "English (United Kingdom)"),
        .init(id: "en-US", name: "English (United States)"),
        .init(id: "yue-CN", name: "Cantonese (China mainland)"),
        .init(id: "yue-HK", name: "Cantonese (Hong Kong)"),
        .init(id: "zh-CN", name: "Chinese (China mainland)"),
        .init(id: "zh-TW", name: "Chinese (Taiwan)"),
        .init(id: "fr-CA", name: "French (Canada)"),
        .init(id: "fr-FR", name: "French (France)"),
        .init(id: "de-DE", name: "German (Germany)"),
        .init(id: "ja-JP", name: "Japanese (Japan)"),
        .init(id: "ko-KR", name: "Korean (South Korea)"),
        .init(id: "es-MX", name: "Spanish (Mexico)"),
        .init(id: "es-ES", name: "Spanish (Spain)"),
        .init(id: "es-US", name: "Spanish (United States)")
    ]
    private static let aliases = ["en": "en-US", "de": "de-DE", "fr": "fr-FR", "es": "es-ES",
                                  "ja": "ja-JP", "ko": "ko-KR", "zh": "zh-CN", "yue": "yue-HK"]

    static func explicitIdentifier(_ language: String) -> String? {
        let key = language.replacingOccurrences(of: "_", with: "-").lowercased()
        return choices.first { $0.id.lowercased() == key }?.id ?? aliases[key]
    }

    static func identifier(for language: String, systemLocale: Locale = .current) -> String? {
        if !language.isEmpty { return explicitIdentifier(language) }
        // System region need not be a speech dialect (for example English in NL).
        return explicitIdentifier(systemLocale.identifier)
            ?? systemLocale.language.languageCode.flatMap { aliases[$0.identifier] }
    }

    static func requireLocale(for language: String) throws -> Locale {
        guard let identifier = identifier(for: language) else { throw Unavailable() }
        return Locale(identifier: identifier)
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? {
            "This language is not available with Apple Speech. Choose a supported spoken language or another transcription engine."
        }
    }
}
