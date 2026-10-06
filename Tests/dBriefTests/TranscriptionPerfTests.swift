import Foundation
import Testing
import dBriefWire
@testable import dBrief

struct TranscriptionPerfTests {
    @Test func freshTranscriptionCarriesEveryBenchmarkTiming() {
        let result = TranscriptionResult(text: "Hello", inferenceTime: 4, diarizationTime: 2)
        let perf = TranscriptionPerf(fresh: result, model: "Parakeet Phonon-2", audioDuration: 120,
                                     spellCorrection: 1, elapsed: 9)
        #expect(perf.model == "Parakeet Phonon-2")
        #expect(perf.time == 9)
        #expect(perf.inference == 4)
        #expect(perf.diarization == 2)
        #expect(perf.spellCorrection == 1)
        #expect(perf.audioDuration == 120)
        #expect(perf.finalization == nil)
    }
}
