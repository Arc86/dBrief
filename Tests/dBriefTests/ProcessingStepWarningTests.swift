import Testing
@testable import dBrief

@Suite struct ProcessingStepWarningTests {
    @Test func warningsAreReportedAsWarningsNotFailures() throws {
        let step = try #require(ProcessingStep.warnings("Transcription warnings", ["Low volume", "Clipped audio"]))
        #expect(step.name == "Transcription warnings")
        #expect(step.warningMessage == "Low volume\nClipped audio")
        if case .failed = step.status { Issue.record("A warning must not fail the run or hold back integrations") }
    }

    @Test func noWarningsMeansNoStep() {
        #expect(ProcessingStep.warnings("Audio finalization warnings", []) == nil)
    }
}
