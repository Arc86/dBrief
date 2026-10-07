import Foundation

/// Which side of a retrieval pair a text is embedded as. EmbeddingGemma is
/// trained with asymmetric task prefixes, so queries and documents differ.
public enum EmbeddingRole: String, Codable, Sendable {
    case query
    case document
}

/// EmbeddingGemma prompt formatting (the model card's "search result" task
/// prompts) plus the model id, shared by the helper and the app.
public enum EmbeddingPrompt {
    public static let modelID = "mlx-community/embeddinggemma-300m-4bit"

    public static func format(_ text: String, role: EmbeddingRole) -> String {
        switch role {
        case .query: "task: search result | query: \(text)"
        case .document: "title: none | text: \(text)"
        }
    }
}
