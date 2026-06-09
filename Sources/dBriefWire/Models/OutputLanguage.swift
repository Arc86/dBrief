import Foundation

public enum OutputLanguage: Sendable, Equatable, Codable {
    case matchInput
    case english
    case dutch
    case custom(String)

    public var displayName: String {
        switch self {
        case .matchInput: "Match Transcript"
        case .english: "English"
        case .dutch: "Dutch"
        case .custom(let code): "Custom (\(code.uppercased()))"
        }
    }
}
