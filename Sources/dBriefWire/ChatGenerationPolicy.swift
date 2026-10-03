import Foundation

/// App limits, not advertised model context sizes. Shared with actual dispatch.
public enum ChatGenerationPolicy {
    public static let modelID = "mlx-community/gemma-4-e4b-it-4bit"
    public static let maximumOutputTokens = 8_192
    public static let applicationContextTokens = 32_768
    public static func validatePromptTokenCount(_ count: Int) throws {
        guard count > 0, count <= applicationContextTokens - maximumOutputTokens - 256 else {
            throw WireError(kind: .generic, message: "The chat context exceeds the local application limit. Ask a narrower question.")
        }
    }
}
