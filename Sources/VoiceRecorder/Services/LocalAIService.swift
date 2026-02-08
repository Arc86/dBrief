#if canImport(FoundationModels)
import Foundation
import FoundationModels
import os

private let log = Logger(subsystem: "com.voicerecorder.app", category: "localai")

/// On-device AI using Apple Foundation Models (macOS 26+).
@available(macOS 26, *)
actor LocalAIService {
    func generateSummary(transcription: String, systemPrompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: "Summarize this transcription:\n\n\(transcription)")
        return response.content
    }

    func extractActionItems(transcription: String, systemPrompt: String) async throws -> [String] {
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: "Extract action items from this transcription:\n\n\(transcription)")
        return response.content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)) }
    }

    struct TagsResult: Sendable {
        let tags: [String]
        let sentiment: String
    }

    func analyzeTags(transcription: String, systemPrompt: String) async throws -> TagsResult {
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: "Analyze this transcription:\n\n\(transcription)")

        guard let data = response.content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TagsResult(tags: [], sentiment: "neutral")
        }

        let tags = (json["tags"] as? [String]) ?? []
        let sentiment = (json["sentiment"] as? String) ?? "neutral"
        return TagsResult(tags: tags, sentiment: sentiment)
    }

    func generateTitle(transcription: String, language: String?) async throws -> String {
        let langHint = language.map { " The content is in language code '\($0)'." } ?? ""
        let session = LanguageModelSession(instructions: "Generate a short, descriptive title (3-8 words) for the following transcription. Respond with ONLY the title, no quotes, no punctuation at the end, no explanation. The title should be in the same language as the content.\(langHint)")
        let response = try await session.respond(to: transcription)
        return response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }
}
#endif
