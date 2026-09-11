import Foundation
import Testing
@testable import dBrief

struct ReprocessingAnalysisErrorTests {
    @Test func preservesCLIReasonWithoutRepeatingItForEveryField() {
        let reason = LocalCLIServiceError.nonZeroExit(code: 1, stderr: "Authentication expired; sign in again.").localizedDescription
        let output = ProcessingPipeline.AnalysisOutput(failures: [.summary: reason, .actionItems: reason, .tags: reason], modelDisplayName: "Local CLI")
        let message = ReprocessingError.analysisFailure(output).localizedDescription
        #expect(message.contains("Local CLI"))
        #expect(message.components(separatedBy: reason).count == 2)
        #expect(message.contains("Current results were kept"))
    }

    @Test func identifiesMissingFieldsButAllowsEmptyLists() {
        let output = ProcessingPipeline.AnalysisOutput(actionItems: [], tags: [], modelDisplayName: "Local CLI")
        let message = ReprocessingError.analysisFailure(output).localizedDescription
        #expect(message.contains("Summary: no result was returned"))
        #expect(!message.contains("Action items:"))
        #expect(!message.contains("Tags:"))
    }

    @Test func preservesDistinctFieldErrors() {
        let output = ProcessingPipeline.AnalysisOutput(summary: "OK", failures: [.actionItems: "Connection refused", .tags: "Rate limit exceeded"])
        let message = ReprocessingError.analysisFailure(output).localizedDescription
        #expect(message.contains("Action items: Connection refused"))
        #expect(message.contains("Tags: Rate limit exceeded"))
    }
}
