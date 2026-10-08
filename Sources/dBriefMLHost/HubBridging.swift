import Foundation
import Hub
import MLXLMCommon
import Tokenizers

// MARK: - HuggingFace bridging for mlx-swift-lm 3.x Downloader/TokenizerLoader protocols

struct HubApiDownloader: Downloader {
    let hub: HubApi

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hub.snapshot(
            from: id,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

struct TransformersTokenizerLoader: TokenizerLoader {
    let fallbackChatTemplate: String?

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream, fallbackChatTemplate: fallbackChatTemplate)
    }
}

struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    private let fallbackChatTemplate: String?

    init(_ upstream: any Tokenizers.Tokenizer, fallbackChatTemplate: String? = nil) {
        self.upstream = upstream
        self.fallbackChatTemplate = fallbackChatTemplate
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            guard let fallbackChatTemplate else {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            return try upstream.applyChatTemplate(
                messages: messages,
                chatTemplate: .literal(fallbackChatTemplate),
                addGenerationPrompt: true,
                truncation: false,
                maxLength: nil,
                tools: tools,
                additionalContext: additionalContext
            )
        }
    }
}
