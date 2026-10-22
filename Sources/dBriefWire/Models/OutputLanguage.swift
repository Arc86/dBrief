import Foundation

public enum OutputLanguage: Sendable, Equatable, Codable {
    case matchInput
    case english
    case dutch
    case german
    case french
    case spanish
    case custom(String)

    public var displayName: String {
        switch self {
        case .matchInput: "Match Transcript"
        case .english: "English"
        case .dutch: "Dutch"
        case .german: "German"
        case .french: "French"
        case .spanish: "Spanish"
        case .custom(let code): "Custom (\(code.uppercased()))"
        }
    }

    /// The line every analysis prompt carries (unified engines and remote per-task prompts).
    public var promptInstruction: String {
        switch self {
        case .english: Self.translate("ENGLISH")
        case .dutch: Self.translate("DUTCH")
        case .german: Self.translate("GERMAN")
        case .french: Self.translate("FRENCH")
        case .spanish: Self.translate("SPANISH")
        case .custom(let code): "OUTPUT LANGUAGE: ISO Code \(code.uppercased())."
        case .matchInput: "OUTPUT LANGUAGE: Match the language of the transcript exactly."
        }
    }

    private static func translate(_ name: String) -> String {
        "OUTPUT LANGUAGE: \(name) (Must translate if transcript is different)."
    }
}
