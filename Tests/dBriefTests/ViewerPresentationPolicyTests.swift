import Testing
@testable import dBrief

@Suite struct ViewerPresentationPolicyTests {
    @Test func playbackBelongsOnlyToFinalizedTranscriptView() {
        for mode in ViewerDocumentMode.allCases {
            #expect(
                ViewerPresentationPolicy.showsPlayback(
                    mode: mode,
                    hasFinalizedAudio: true,
                    isLive: false
                ) == (mode == .transcript)
            )
            #expect(
                !ViewerPresentationPolicy.showsPlayback(
                    mode: mode,
                    hasFinalizedAudio: false,
                    isLive: false
                )
            )
            #expect(
                !ViewerPresentationPolicy.showsPlayback(
                    mode: mode,
                    hasFinalizedAudio: true,
                    isLive: true
                )
            )
        }
    }

    @Test func initialModeUsesSummaryWhenAvailable() {
        #expect(ViewerPresentationPolicy.initialMode(hasSummary: true) == .summary)
        #expect(ViewerPresentationPolicy.initialMode(hasSummary: false) == .transcript)
    }

}
