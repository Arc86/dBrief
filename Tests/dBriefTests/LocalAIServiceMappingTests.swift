import Testing
@testable import dBrief

#if canImport(FoundationModels)
import FoundationModels

/// Pure mapping tests for the Apple Intelligence backend. These exercise the
/// sentiment-canonicalization and availability-message helpers WITHOUT invoking the
/// on-device model (which needs entitlement + hardware). Gated to macOS 26 because
/// the helpers reference FoundationModels types.
@available(macOS 26, *)
struct LocalAIServiceMappingTests {

    @Test("Sentiment maps to the canonical capitalized strings")
    func sentimentCanonical() {
        #expect(LocalAIService.Sentiment.positive.canonical == "Positive")
        #expect(LocalAIService.Sentiment.neutral.canonical == "Neutral")
        #expect(LocalAIService.Sentiment.negative.canonical == "Negative")
    }

    @Test("Each unavailable reason produces a distinct, specific message")
    func availabilityMessages() {
        let eligible = LocalAIService.message(for: .deviceNotEligible)
        let notEnabled = LocalAIService.message(for: .appleIntelligenceNotEnabled)
        let notReady = LocalAIService.message(for: .modelNotReady)
        #expect(eligible != notEnabled)
        #expect(notEnabled != notReady)
        #expect(notEnabled.contains("System Settings"))
        #expect(notReady.lowercased().contains("download") || notReady.lowercased().contains("not ready"))
    }
}
#endif
