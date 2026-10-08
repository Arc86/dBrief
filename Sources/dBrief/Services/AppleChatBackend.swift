import Foundation
import dBriefWire
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Retry policy for Apple Intelligence chat: one retry with a smaller context after
/// an overflow, nothing else. Pure, so it is testable without the model.
enum AppleChatAttempt: Equatable {
    case first, retryShrunk

    static let overflowMessage = overflowMessage(canScan: true)

    /// `canScan`: the "Check the whole recording" button is offered (a finished recording).
    static func overflowMessage(canScan: Bool) -> String {
        "This question needs more of the recording than Apple Intelligence can hold at once. "
            + (canScan ? "Try a narrower question, or use “Check the whole recording”." : "Try a narrower question.")
    }

    static func next(after error: Error, attempt: AppleChatAttempt, isOverflow: (Error) -> Bool) -> AppleChatAttempt? {
        attempt == .first && isOverflow(error) ? .retryShrunk : nil
    }
}

enum AppleChatContext {
    /// The most recent whole lines of a transcript that fit `budgetTokens`, for a long
    /// transcript that has no turns to retrieve from (live chat). When not even the last
    /// line fits, its end is kept.
    static func recentTail(_ transcript: String, budgetTokens: Int, countTokens: (String) -> Int) -> String {
        guard countTokens(transcript) > budgetTokens else { return transcript }
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var used = 0
        for line in lines.reversed() {
            let cost = countTokens(String(line)) + (kept.isEmpty ? 0 : 1)
            guard used + cost <= budgetTokens else { break }
            kept.append(line)
            used += cost
        }
        if !kept.isEmpty { return kept.reversed().joined(separator: "\n") }
        // Binary search the longest suffix of the last line that fits.
        let last = lines.last.map(String.init) ?? transcript
        var low = 0, high = last.count
        while low < high {
            let mid = (low + high + 1) / 2
            if countTokens(String(last.suffix(mid))) <= budgetTokens { low = mid } else { high = mid - 1 }
        }
        return String(last.suffix(low))
    }
}

#if canImport(FoundationModels)
/// One-shot Apple Intelligence chat calls. Every question runs in a fresh session,
/// so the prompt carries the compact history itself.
@available(macOS 26, *)
enum AppleChatBackend {
    static var profile: ChatEngineProfile {
        .appleIntelligence(contextSize: SystemLanguageModel.default.contextSize)
    }

    /// Exact on macOS 26.4+ (`tokenCount`), conservative estimate before.
    static func tokenCount(_ text: String) async -> Int {
        if #available(macOS 26.4, *), let exact = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return exact
        }
        return ChatEngineProfile.estimateTokens(text)
    }

    static func respond(instructions: String, prompt: String) async throws -> String {
        try LocalAIService.ensureAvailable()
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.5)
        let response = try await PrivacyTrace.perform(.init(stage: .chat, data: [.text, .metadata], destination: .local(provider: .appleIntelligence))) {
            try await session.respond(to: prompt, options: options)
        }
        return response.content
    }

    /// OS-neutral: covers the macOS 26 `GenerationError` and the macOS 27 `LanguageModelError`.
    static func isContextOverflow(_ error: Error) -> Bool {
        AppleGenerationFailure.classify(error) == .overflow
    }

    /// What the chat shows for a failed answer; never a raw framework error.
    /// `canScan`: whether an overflow may point to "Check the whole recording".
    static func userMessage(for error: Error, canScan: Bool = true) -> String {
        guard let failure = AppleGenerationFailure.classify(error) else { return error.localizedDescription }
        switch failure {
        case .overflow:
            return AppleChatAttempt.overflowMessage(canScan: canScan)
        case .refusal:
            return "Apple Intelligence declined to answer this question. Try rephrasing it, or choose a different AI engine."
        case .guardrail:
            return "Apple Intelligence blocked this question with its safety guardrails. Try rephrasing it."
        case .decoding, .unsupportedLanguage:
            return failure.message ?? error.localizedDescription
        case .other:
            return "Apple Intelligence couldn't answer right now. Try again, or choose a different AI engine."
        }
    }
}
#endif
