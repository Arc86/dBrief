import Testing
@testable import dBrief

/// A failed brief used to offer "Retry AI" only for remote endpoints (found by matching
/// step names), nothing for failed sends, and still read "Brief ready" in green.
@Suite struct BriefRecoveryTests {
    @Test func eachFailedKindOffersItsFix() {
        let steps = [
            ProcessingStep(name: "Transcribing", status: .completed, kind: .transcription),
            ProcessingStep(name: "Generating summary (Gemma 4 E4B local)", status: .failed("Model unavailable"), kind: .analysis),
            ProcessingStep(name: "Send: Notion", status: .failed("Not sent"), kind: .delivery),
        ]
        #expect(BriefRecovery.actions(for: steps) == [.reanalyze, .integrations])
        #expect(BriefRecovery.actions(for: [steps[0]]).isEmpty)
    }

    /// "Finalizing audio" contains "ai"; name matching offered an AI retry for it.
    @Test func stepNamesNoLongerDecide() {
        let audio = ProcessingStep(name: "Finalizing audio", status: .failed("Disk full"), kind: .other)
        #expect(BriefRecovery.actions(for: [audio]).isEmpty)
    }

    @Test func warningsNeedNoFix() {
        let warning = ProcessingStep(name: "Transcription warnings", status: .warning("Low volume"), kind: .transcription)
        #expect(BriefRecovery.actions(for: [warning]).isEmpty)
        #expect(!BriefRecovery.hasFailures([warning]))
    }
}
