import Foundation
import Testing
@testable import dBrief

struct FinalizationWarningTests {

    // Benign "one source was silent/absent" notes — e.g. a listen-only meeting
    // where the mic captured nothing — must classify as informational so the UI
    // doesn't show a red error step.
    @Test func micEmptyIsInformational() {
        #expect(FinalizationWarning.isInformational("Mic track missing or empty (dbrief-raw-ABC.mic.caf)."))
    }

    @Test func systemEmptyIsInformational() {
        #expect(FinalizationWarning.isInformational(
            "System audio track missing or empty (dbrief-raw-ABC.system.caf); using mic-only output."))
    }

    // Genuine problems must NOT be suppressed — they stay surfaced as errors.
    @Test func genuineProblemsAreNotInformational() {
        #expect(!FinalizationWarning.isInformational("ffmpeg not found. Skipped merge and AAC encode; master is raw CAF."))
        #expect(!FinalizationWarning.isInformational("ffmpeg merge failed; keeping raw CAF(s). broken pipe"))
        #expect(!FinalizationWarning.isInformational("Segmentation produced no output files."))
        #expect(!FinalizationWarning.isInformational("Segmentation failed. disk full"))
    }

    // The marker used by the classifier must match the strings the finalizer
    // actually emits (they're built from the same constant), guarding drift.
    @Test func markerMatchesEmittedMessages() {
        let mic = "Mic \(FinalizationWarning.emptyTrackMarker) (x.mic.caf)."
        let system = "System audio \(FinalizationWarning.emptyTrackMarker) (x.system.caf); using mic-only output."
        #expect(FinalizationWarning.isInformational(mic))
        #expect(FinalizationWarning.isInformational(system))
    }
}
