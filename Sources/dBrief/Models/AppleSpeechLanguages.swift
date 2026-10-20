import Foundation

/// Product allowlist from macOS Live Captions, verified 2026-09-13.
/// Keep separate from Apple's locale lookup, which can advertise unavailable assets.
enum AppleSpeechLanguages {
    struct Choice: Identifiable, Sendable {
        let id: String
        let name: String
    }
    static let choices: [Choice] = [
        .init(id: "en-AU", name: String(localized: "English (Australia)")),
        .init(id: "en-CA", name: String(localized: "English (Canada)")),
        .init(id: "en-IN", name: String(localized: "English (India)")),
        .init(id: "en-SG", name: String(localized: "English (Singapore)")),
        .init(id: "en-GB", name: String(localized: "English (United Kingdom)")),
        .init(id: "en-US", name: String(localized: "English (United States)")),
        .init(id: "yue-CN", name: String(localized: "Cantonese (China mainland)")),
        .init(id: "yue-HK", name: String(localized: "Cantonese (Hong Kong)")),
        .init(id: "zh-CN", name: String(localized: "Chinese (China mainland)")),
        .init(id: "zh-TW", name: String(localized: "Chinese (Taiwan)")),
        .init(id: "fr-CA", name: String(localized: "French (Canada)")),
        .init(id: "fr-FR", name: String(localized: "French (France)")),
        .init(id: "de-DE", name: String(localized: "German (Germany)")),
        .init(id: "ja-JP", name: String(localized: "Japanese (Japan)")),
        .init(id: "ko-KR", name: String(localized: "Korean (South Korea)")),
        .init(id: "es-MX", name: String(localized: "Spanish (Mexico)")),
        .init(id: "es-ES", name: String(localized: "Spanish (Spain)")),
        .init(id: "es-US", name: String(localized: "Spanish (United States)"))
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
            String(localized: "This language is not available with Apple Speech. Choose a supported spoken language or another transcription engine.")
        }
    }
}
