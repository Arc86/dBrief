#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import dBrief

@Suite struct AppleGenerationFailureTests {
    @available(macOS 26, *)
    private func context() -> LanguageModelSession.GenerationError.Context { .init(debugDescription: "test") }

    @Test func classifiesGenerationErrors() {
        guard #available(macOS 26, *) else { return }
        typealias E = LanguageModelSession.GenerationError
        #expect(AppleGenerationFailure.classify(E.exceededContextWindowSize(context())) == .overflow)
        #expect(AppleGenerationFailure.classify(E.decodingFailure(context())) == .decoding)
        #expect(AppleGenerationFailure.classify(E.refusal(.init(transcriptEntries: []), context())) == .refusal)
        #expect(AppleGenerationFailure.classify(E.guardrailViolation(context())) == .guardrail)
        #expect(AppleGenerationFailure.classify(E.unsupportedLanguageOrLocale(context())) == .unsupportedLanguage)
        #expect(AppleGenerationFailure.classify(E.rateLimited(context())) == .other)
    }

    @Test func leavesNonGenerationErrorsAlone() {
        guard #available(macOS 26, *) else { return }
        #expect(AppleGenerationFailure.classify(CancellationError()) == nil)
        #expect(AppleGenerationFailure.classify(LocalAIError.generation("x")) == nil)
    }

    @Test func decisionsFollowTheClassifiedFailure() {
        guard #available(macOS 26, *) else { return }
        let all: [AppleGenerationFailure] = [.overflow, .refusal, .guardrail, .decoding, .unsupportedLanguage, .other]
        #expect(all.filter(\.splitMayHelp) == [.overflow, .refusal, .guardrail, .decoding])
        #expect(all.filter(\.retryAsText) == [.refusal, .guardrail])
    }

    @Test func overflowMessageMatchesThePromptPreviewMapping() {
        guard #available(macOS 26, *) else { return }
        // PromptPreviewError.fromAnalysisFailure recognises this exact text as a context limit.
        #expect(AppleGenerationFailure.overflow.message
                == "Part of this recording was too dense for Apple Intelligence even after splitting. Try a different AI engine.")
        #expect(AppleGenerationFailure.other.message == nil)
    }
}
#endif
