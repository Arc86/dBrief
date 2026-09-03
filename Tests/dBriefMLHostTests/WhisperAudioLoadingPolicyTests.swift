import Foundation
import Testing
@testable import dBriefMLHost

@Suite("Whisper audio loading policy")
struct WhisperAudioLoadingPolicyTests {
    @Test("Long recordings without diarization use incremental loading")
    func longRecordingUsesIncrementalLoading() {
        #expect(WhisperAudioLoadingPolicy.shouldLoadIncrementally(
            durationSeconds: WhisperAudioLoadingPolicy.incrementalThresholdSeconds,
            diarizationEnabled: false
        ))
    }

    @Test("Short recordings retain full-buffer loading")
    func shortRecordingUsesBufferedLoading() {
        #expect(!WhisperAudioLoadingPolicy.shouldLoadIncrementally(
            durationSeconds: WhisperAudioLoadingPolicy.incrementalThresholdSeconds - 1,
            diarizationEnabled: false
        ))
    }

    @Test("Diarization always retains full-buffer loading")
    func diarizationUsesBufferedLoading() {
        #expect(!WhisperAudioLoadingPolicy.shouldLoadIncrementally(
            durationSeconds: WhisperAudioLoadingPolicy.incrementalThresholdSeconds * 3,
            diarizationEnabled: true
        ))
    }

    @Test("Unknown and invalid durations safely retain full-buffer loading", arguments: [
        nil,
        -1,
        .infinity,
        .nan,
    ] as [TimeInterval?])
    func invalidDurationUsesBufferedLoading(duration: TimeInterval?) {
        #expect(!WhisperAudioLoadingPolicy.shouldLoadIncrementally(
            durationSeconds: duration,
            diarizationEnabled: false
        ))
    }
}
