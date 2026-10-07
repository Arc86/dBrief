import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXLMCommon
import OSLog
import dBriefWire

/// EmbeddingGemma-300M (4-bit, 768-d) for transcript-chat retrieval. Small enough
/// (~210 MB) to stay resident beside Gemma during a chat; unloaded with it
/// (`GemmaChatSessions.drop()`, which every non-chat operation and `forceUnload` run).
actor EmbeddingService {
    private var container: EmbedderModelContainer?
    private let fallbackStateHandler: MLProgress.Sink
    nonisolated private var stateHandler: MLProgress.Sink { MLProgress.sink ?? fallbackStateHandler }
    static let batchSize = 16
    static let maxTokens = 1024 // windows are ~350 tokens; model limit is 2048

    init(stateHandler: @escaping MLProgress.Sink = { _ in }) { self.fallbackStateHandler = stateHandler }

    var isLoaded: Bool { container != nil }

    /// One L2-normalized vector per text, in input order. Texts are formatted
    /// with the EmbeddingGemma task prefix for `role` before tokenizing.
    func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await loadIfNeeded()
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = texts[start..<min(start + Self.batchSize, texts.count)]
                .map { EmbeddingPrompt.format($0, role: role) }
            out += await container.perform { ctx in
                let encoded = batch.map { Array(ctx.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(Self.maxTokens)) }
                let maxLen = max(encoded.map(\.count).max() ?? 1, 1)
                // Gemma's <pad> is id 0, which is also what EmbeddingGemma's own
                // no-mask fallback treats as padding.
                let padID = ctx.tokenizer.convertTokenToId("<pad>") ?? 0
                let ids = MLXArray(encoded.flatMap { row in
                    row.map(Int32.init) + Array(repeating: Int32(padID), count: maxLen - row.count)
                }).reshaped(encoded.count, maxLen)
                // EmbeddingGemma uses the mask only for mean pooling (multiply +
                // sum over tokens), never inside attention, so an integer 0/1 mask
                // is correct. Right padding is safe: the backbone's attention is
                // causal, so real tokens never attend to trailing pads.
                let mask = MLXArray(encoded.flatMap {
                    Array(repeating: Int32(1), count: $0.count) + Array(repeating: Int32(0), count: maxLen - $0.count)
                }).reshaped(encoded.count, maxLen)
                let output = ctx.model(ids, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
                // EmbeddingGemma always returns pooledOutput (masked mean + dense
                // head + L2 norm). The generic pooling fallback would skip the
                // dense head, so it is a degraded last resort only.
                assert(output.pooledOutput != nil, "EmbeddingGemma returned no pooledOutput")
                let pooled: MLXArray
                if let p = output.pooledOutput {
                    pooled = p
                } else {
                    Logger.ai.error("Embedding: model returned no pooled output; using generic pooling")
                    pooled = ctx.pooling(output, mask: mask)
                }
                // pooledOutput is already unit-length; re-normalizing keeps the
                // fallback path (and any future model) cosine-ready too.
                let f = pooled.asType(.float32)
                let normalized = f / MLX.maximum(sqrt(sum(f * f, axis: -1, keepDims: true)), MLXArray(Float(1e-6)))
                normalized.eval()
                return (0..<encoded.count).map { normalized[$0].asArray(Float.self) }
            }
        }
        return out
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
            configuration: .init(id: EmbeddingPrompt.modelID),
            progressHandler: { p in handler(.downloading(progress: p.fractionCompleted, stage: .embeddingModel)) })
        container = loaded
        return loaded
    }
}
