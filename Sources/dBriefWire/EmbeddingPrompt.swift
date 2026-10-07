import Foundation

/// Which side of a retrieval pair a text is embedded as. Asymmetric models
/// (EmbeddingGemma, E5) use different prefixes for queries and documents.
public enum EmbeddingRole: String, Codable, Sendable {
    case query
    case document
}

/// One retrieval embedding model: its Hugging Face id, task prefixes and how a
/// sentence vector is pooled from the model output. Vector width is whatever the
/// model returns — never assume a dimension.
public struct EmbeddingModelSpec: Sendable, Equatable {
    public enum Pooling: String, Sendable {
        /// The model's own `pooledOutput` (EmbeddingGemma: masked mean + dense head).
        case modelOutput
        /// Masked mean over token hidden states (sentence-transformers mean pooling).
        case mean
        /// The first ([CLS]) token's hidden state.
        case cls
    }

    public let id: String
    public let queryPrefix: String
    public let documentPrefix: String
    public let pooling: Pooling

    public init(id: String, queryPrefix: String, documentPrefix: String, pooling: Pooling) {
        self.id = id
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
        self.pooling = pooling
    }

    /// EmbeddingGemma-300M, 4-bit. Prefixes from the model card's "search result" task.
    public static let embeddingGemma300m4bit = EmbeddingModelSpec(
        id: "mlx-community/embeddinggemma-300m-4bit",
        queryPrefix: "task: search result | query: ", documentPrefix: "title: none | text: ",
        pooling: .modelOutput)
    /// Multilingual E5 small (bidirectional XLM-R encoder), mean pooled.
    public static let multilingualE5Small = EmbeddingModelSpec(
        id: "intfloat/multilingual-e5-small",
        queryPrefix: "query: ", documentPrefix: "passage: ", pooling: .mean)
    /// BGE-M3 dense retrieval (XLM-R large), CLS pooled, no prefixes. Not in `known`:
    /// its repo has no root *.safetensors (pytorch_model.bin + onnx/ only), so it can't load.
    public static let bgeM3 = EmbeddingModelSpec(
        id: "BAAI/bge-m3", queryPrefix: "", documentPrefix: "", pooling: .cls)

    public static let known: [EmbeddingModelSpec] = [embeddingGemma300m4bit, multilingualE5Small]

    /// Lookup by Hugging Face id (eval tooling only; production uses `EmbeddingPrompt.current`).
    public static func named(_ id: String) -> EmbeddingModelSpec? {
        known.first { $0.id == id }
    }

    public func format(_ text: String, role: EmbeddingRole) -> String {
        (role == .query ? queryPrefix : documentPrefix) + text
    }
}

/// The retrieval embedding model the app and helper use, shared by both sides.
/// Chosen by `scripts/chat-eval.py --retrieval` on the planted L transcript:
/// multilingual-e5-small put all 3 needles at fused rank 1 (EmbeddingGemma, run
/// causally by the mlx-swift-lm port: 8/3/1). Index sidecars store the model id,
/// so changing this only rebuilds indexes.
public enum EmbeddingPrompt {
    public static let current: EmbeddingModelSpec = .multilingualE5Small
    public static var modelID: String { current.id }

    public static func format(_ text: String, role: EmbeddingRole, spec: EmbeddingModelSpec = current) -> String {
        spec.format(text, role: role)
    }
}
