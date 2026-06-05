import Testing
@testable import dBrief

@Suite("Model download mapping")
struct ModelDownloadTests {

    @Test("maps a fractional download to a determinate phase")
    func mapsDownloadingProgress() {
        let phase = ModelDownloadPhase.from(pluginState: .downloading(progress: 0.42, stage: .whisperModel))
        #expect(phase == .downloading(progress: 0.42, label: "Downloading…"))
    }

    @Test("maps the loading stage to an indeterminate phase")
    func mapsLoadingStageIndeterminate() {
        let phase = ModelDownloadPhase.from(pluginState: .downloading(progress: nil, stage: .whisperModelLoading))
        #expect(phase == .downloading(progress: nil, label: "Loading…"))
    }

    @Test("ignores non-download states")
    func ignoresNonDownloadStates() {
        #expect(ModelDownloadPhase.from(pluginState: .idle) == nil)
        #expect(ModelDownloadPhase.from(pluginState: .transcribing) == nil)
        #expect(ModelDownloadPhase.from(pluginState: .analyzing) == nil)
        #expect(ModelDownloadPhase.from(pluginState: .diarizing) == nil)
    }

    @Test("engine guide lists all six engines with non-empty content")
    func engineGuideContent() {
        let entries = TranscriptionEngineGuide.entries
        #expect(entries.count == 6)
        for entry in entries {
            #expect(!entry.title.isEmpty)
            #expect(!entry.detail.isEmpty)
        }
    }
}
