import Foundation
import Testing
@testable import dBrief

@Suite("Processing checkpoints")
struct ProcessingCheckpointTests {
    @Test
    func newJobStartsAtAudioFinalization() {
        let checkpoint = ProcessingCheckpoint(
            jobID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(checkpoint.lastCompletedStage == nil)
        #expect(checkpoint.nextStage == .audioFinalized)
    }

    @Test
    func transitionsAreMonotonicAndIdempotent() {
        let initialDate = Date(timeIntervalSince1970: 100)
        let advancedDate = Date(timeIntervalSince1970: 200)
        var checkpoint = ProcessingCheckpoint(jobID: UUID(), updatedAt: initialDate)

        let didAdvance = checkpoint.markCompleted(.transcribed, at: advancedDate)
        #expect(didAdvance)
        #expect(checkpoint.lastCompletedStage == .transcribed)
        #expect(checkpoint.updatedAt == advancedDate)
        let repeatedStageChanged = checkpoint.markCompleted(
            .transcribed,
            at: Date(timeIntervalSince1970: 300)
        )
        let regressedStageChanged = checkpoint.markCompleted(
            .audioFinalized,
            at: Date(timeIntervalSince1970: 400)
        )
        #expect(!repeatedStageChanged)
        #expect(!regressedStageChanged)
        #expect(checkpoint.updatedAt == advancedDate)
        #expect(checkpoint.nextStage == .diarized)
    }

    @Test
    func completedCheckpointHasNoNextStageAndRoundTrips() throws {
        var checkpoint = ProcessingCheckpoint(
            jobID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        checkpoint.markCompleted(.integrationsDispatched, at: Date(timeIntervalSince1970: 200))

        let encoded = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(ProcessingCheckpoint.self, from: encoded)

        #expect(decoded == checkpoint)
        #expect(decoded.version == ProcessingCheckpoint.currentVersion)
        #expect(decoded.nextStage == nil)
    }
}
