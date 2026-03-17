#if canImport(FoundationModels)
import Foundation
import FoundationModels
import os

private let log = Logger.localAI

/// On-device AI using Apple Foundation Models (macOS 26+).
@available(macOS 26, *)
actor LocalAIService {
    private static let transcriptCharLimit = 12_000
    private static let transcriptHeadChars = 6_000
    private static let transcriptTailChars = 6_000
    private static let truncationSeparator = "\n\n[...MIDDLE TEXT OMITTED FOR BREVITY...]\n\n"

    private static func truncateTranscript(_ transcript: String) -> String {
        guard transcript.count > transcriptCharLimit else { return transcript }
        let head = String(transcript.prefix(transcriptHeadChars))
        let tail = String(transcript.suffix(transcriptTailChars))
        return head + truncationSeparator + tail
    }
    func generateSummary(transcription: String, systemPrompt: String) async throws -> String {
        let truncated = Self.truncateTranscript(transcription)
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: "Summarize this transcription:\n\n\(truncated)")
        return response.content
    }

    func extractActionItems(transcription: String, systemPrompt: String) async throws -> [String] {
        let truncated = Self.truncateTranscript(transcription)
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: "Extract action items from this transcription:\n\n\(truncated)")
        
        return response.content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") } // Ignore empty lines and markdown blocks
            .map { line -> String in
                // Strip common list prefixes: "- ", "* ", or numbered lists like "1. "
                let pattern = "^[-*]\\s+|^\\d+\\.\\s+"
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let prefixLength = match.range.length
                    let index = line.index(line.startIndex, offsetBy: prefixLength)
                    return String(line[index...])
                }
                return line
            }
            // Filter out conversational filler and obvious non-action-items
            .filter { line in
                let lower = line.lowercased()
                let fillers = ["here are the action items", "action items:", "no action items", "none"]
                return !fillers.contains { lower.hasPrefix($0) } && line.count > 5
            }
    }

    struct TagsResult: Sendable {
        let tags: [String]
        let sentiment: String
    }

    func analyzeTags(transcription: String, systemPrompt: String) async throws -> TagsResult {
        let truncated = Self.truncateTranscript(transcription)
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: "Analyze this transcription:\n\n\(truncated)")

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
