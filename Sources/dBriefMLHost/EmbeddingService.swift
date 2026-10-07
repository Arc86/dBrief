import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXLMCommon
import OSLog
import dBriefWire

/// Retrieval embeddings for transcript chat (`EmbeddingPrompt.current` in
/// production; the eval may pass another `EmbeddingModelSpec`). Small enough to
/// stay resident beside Gemma during a chat; unloaded with it
/// (`GemmaChatSessions.drop()`, which every non-chat operation and `forceUnload` run).
/// Vector width comes from the model — nothing here assumes a dimension.
actor EmbeddingService {
    let spec: EmbeddingModelSpec
    private var container: EmbedderModelContainer?
    private let fallbackStateHandler: MLProgress.Sink
    nonisolated private var stateHandler: MLProgress.Sink { MLProgress.sink ?? fallbackStateHandler }
    static let batchSize = 16
    static let maxTokens = 1024 // windows are ~350 tokens; capped further by the model's position limit

    init(spec: EmbeddingModelSpec = EmbeddingPrompt.current, stateHandler: @escaping MLProgress.Sink = { _ in }) {
        self.spec = spec
        self.fallbackStateHandler = stateHandler
    }

    var isLoaded: Bool { container != nil }

    /// One L2-normalized vector per text, in input order. Texts get the spec's
    /// task prefix for `role` before tokenizing.
    func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await loadIfNeeded()
        let spec = self.spec
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = texts[start..<min(start + Self.batchSize, texts.count)]
                .map { spec.format($0, role: role) }
            out += await container.perform { ctx in
                // Truncate ourselves so the pooling mask always matches the model's
                // sequence (encoders like XLM-R would otherwise truncate internally).
                let limit = min(Self.maxTokens, ctx.model.maxPositionEmbeddings ?? Self.maxTokens)
                let encoded = batch.map { Array(ctx.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(limit)) }
                let maxLen = max(encoded.map(\.count).max() ?? 1, 1)
                // Right padding with the tokenizer's own <pad> (Gemma: 0, XLM-R: 1);
                // padding-aware position ids (RoBERTa family) key on this id.
                let padID = ctx.tokenizer.convertTokenToId("<pad>") ?? 0
                let ids = MLXArray(encoded.flatMap { row in
                    row.map(Int32.init) + Array(repeating: Int32(padID), count: maxLen - row.count)
                }).reshaped(encoded.count, maxLen)
                // 0/1 integer mask. EmbeddingGemma uses it only for mean pooling;
                // the BERT family converts it to an additive attention mask itself.
                let mask = MLXArray(encoded.flatMap {
                    Array(repeating: Int32(1), count: $0.count) + Array(repeating: Int32(0), count: maxLen - $0.count)
                }).reshaped(encoded.count, maxLen)
                let output = ctx.model(ids, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
                let pooled = Self.pool(output, mask: mask, pooling: spec.pooling)
                let f = pooled.asType(.float32)
                let normalized = f / MLX.maximum(sqrt(sum(f * f, axis: -1, keepDims: true)), MLXArray(Float(1e-6)))
                normalized.eval()
                return (0..<encoded.count).map { normalized[$0].asArray(Float.self) }
            }
        }
        return out
    }

    /// Explicit per-model pooling. The library's generic `Pooling` is not used:
    /// for `.cls` it prefers BERT's `pooledOutput`, which is tanh(pooler(CLS)),
    /// not the sentence-transformers CLS embedding.
    private static func pool(_ output: EmbeddingModelOutput, mask: MLXArray,
                             pooling: EmbeddingModelSpec.Pooling) -> MLXArray {
        switch pooling {
        case .modelOutput:
            // EmbeddingGemma always returns pooledOutput (masked mean + dense head).
            assert(output.pooledOutput != nil, "embedding model returned no pooledOutput")
            if let p = output.pooledOutput { return p }
            Logger.ai.error("Embedding: model returned no pooled output; falling back to mean pooling")
            return pool(output, mask: mask, pooling: .mean)
        case .mean:
            let hidden = output.hiddenStates!.asType(.float32)
            let m = mask.asType(.float32)
            return sum(hidden * m.expandedDimensions(axes: [-1]), axis: 1)
                / MLX.maximum(sum(m, axis: -1, keepDims: true), MLXArray(Float(1)))
        case .cls:
            return output.hiddenStates![0..., 0, 0...]
        }
    }

    func unload() {
        guard container != nil else { return }
        container = nil
        MLX.Memory.clearCache()
    }

    private func loadIfNeeded() async throws -> EmbedderModelContainer {
        if let container { return container }
        let hub = HubApi(downloadBase: try SupportPaths.subdirectory("Embeddings"))
        // Resolve the request's progress sink here: the progress callback runs
        // outside this task, where the task-local sink is not visible.
        let handler = stateHandler
        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: HubApiDownloader(hub: hub),
            using: TransformersTokenizerLoader(fallbackChatTemplate: nil),
            configuration: .init(id: spec.id),
            progressHandler: { p in handler(.downloading(progress: p.fractionCompleted, stage: .embeddingModel)) })
        container = loaded
        return loaded
    }
}
