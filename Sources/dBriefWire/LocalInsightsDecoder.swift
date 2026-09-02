import Foundation
import os

/// Parses and normalizes a local LLM's JSON insights output. Shared by the
/// helper's MLX service (which decodes its own output) and the app (which
/// accumulates streamed tokens then decodes the assembled JSON).
public enum LocalInsightsDecoder {
    public static func decodeAndNormalize(_ raw: String) throws -> LocalInsightsResult {
        guard let jsonPayload = extractFirstJSONObject(raw) else {
            Logger.ai.error("Local insights JSON parse failed: outputLength=\(raw.count)")
            throw NSError(domain: "LocalInsightsDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model output did not contain valid JSON object."])
        }
        guard let data = jsonPayload.data(using: .utf8) else {
            throw NSError(domain: "LocalInsightsDecoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode model JSON text as UTF-8."])
        }

        let decoded = try JSONDecoder().decode(LocalInsightsResult.self, from: data)
        let normalizedTags = normalizeTags(decoded.tags)
        let normalizedSentiment = normalizeSentiment(decoded.sentiment)
        let normalizedActionItems = decoded.actionItems.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        return LocalInsightsResult(
            titleConcept: decoded.titleConcept.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            actionItems: normalizedActionItems,
            tags: normalizedTags,
            sentiment: normalizedSentiment
        )
    }

    /// Extracts the first balanced top-level JSON object from arbitrary model
    /// output, skipping any `<think>…</think>` reasoning block and tolerating
    /// surrounding prose or Markdown code fences. Shared by the local insights
    /// path and the remote `/v1/chat/completions` path.
    public static func extractFirstJSONObject(_ input: String) -> String? {
        // Reasoning models (Gemma 4) emit <think>…</think> before the answer.
        // Search for JSON only after the last closing tag to avoid partial matches
        // inside the thinking block.
        let searchIn: String
        if let thinkEnd = input.range(of: "</think>", options: .backwards) {
            searchIn = String(input[thinkEnd.upperBound...])
        } else {
            searchIn = input
        }

        guard let start = searchIn.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false

        for idx in searchIn[start...].indices {
            let char = searchIn[idx]

            if inString {
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }

            if char == "\"" {
                inString = true
                continue
            }

            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(searchIn[start...idx])
                }
            }
        }

        return nil
    }

    private static func normalizeTags(_ tags: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for tag in tags {
            let cleaned = tag
                .replacingOccurrences(of: #"^#+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let lowered = cleaned.lowercased()
            if !seen.contains(lowered) {
                seen.insert(lowered)
                unique.append(cleaned)
            }
            if unique.count == 10 { break }
        }
        return unique
    }

    private static func normalizeSentiment(_ sentiment: String) -> String {
        switch sentiment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "positive":
            return "Positive"
        case "negative":
            return "Negative"
        default:
            return "Neutral"
        }
    }
}
