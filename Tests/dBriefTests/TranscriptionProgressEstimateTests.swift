import Foundation
import Testing
@testable import dBrief

struct TranscriptionProgressEstimateTests {

    // MARK: - Progress is the further-along of the time baseline and segment coverage

    @Test
    func coverageSnapsForwardWhenItLeadsTheTimeBaseline() {
        // A run FASTER than history predicts: 60s of a 120s file already streamed after
        // only 20s (observed 3× vs historical 2×). Coverage leads the time baseline
        // (20·2/120 = 0.33), so the bar snaps forward to real coverage (0.5).
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 120,
            realtimeRatio: 2,
            elapsed: 20,
            latestSegmentEnd: 60
        )
        #expect(est.progress == 0.5)
        // Coverage is established (≥5%, ≥20s) → observed rate drives the ETA:
        // 60 audio-s / 20 wall-s = 3×; 60 audio-s left → ~20s remaining.
        #expect(est.remaining == "about 20s left")
    }

    @Test
    func laggingBatchedCoverageDoesNotPinTheBar() {
        // Regression: a ~4.5h file at a real 16× (from history). WhisperKit delivered
        // only 41s of segments after 6 min (it batches multi-hour in-memory files), but
        // the run is actually ~35% done. The old contract pinned the bar at ~0.25%
        // coverage; now the time baseline (360·16/16245 ≈ 0.35) keeps it honest.
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 16245,
            realtimeRatio: 16,
            elapsed: 360,
            latestSegmentEnd: 41
        )
        #expect(est.progress != nil)
        #expect(est.progress! > 0.30)
        // Coverage far below 5% → not trustworthy for the ETA; use the ratio estimate.
        // 16245/16 ≈ 1015s predicted − 360 elapsed ≈ 655s ≈ 11 min.
        #expect(est.remaining == "about 11 min left")
    }

    @Test
    func segmentCoverageClampsBelowOne() {
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 100,
            realtimeRatio: nil,
            elapsed: 50,
            latestSegmentEnd: 100 // fully covered but step not yet marked complete
        )
        #expect(est.progress == 0.99)
    }

    @Test
    func segmentCoverageWithoutElapsedHasNoRemaining() {
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 100,
            realtimeRatio: nil,
            elapsed: 0,
            latestSegmentEnd: 20
        )
        #expect(est.progress == 0.2)
        #expect(est.remaining == nil)
    }

    // MARK: - Warm-up guard against absurd early extrapolation

    @Test
    func earlyLongFileDoesNotExtrapolateAbsurdRemaining() {
        // Regression for the "about 2366 min left" bug: a 4.5h file with a fresh
        // install (no history) where only ~41s has streamed after 6 min. The startup
        // ramp makes the observed rate ~0.1× realtime; extrapolating it would predict
        // ~39 hours. With no trustworthy signal we must show NO label, not garbage.
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 16245,
            realtimeRatio: nil,       // fresh beta: empty ModelPerformanceStore
            elapsed: 360,
            latestSegmentEnd: 41
        )
        // Progress still reflects real (tiny) coverage so the bar is honest.
        #expect(est.progress != nil)
        #expect(est.progress! < 0.01)
        // But no misleading "39 hours" label.
        #expect(est.remaining == nil)
    }

    @Test
    func earlyLongFileFallsBackToHistoryWhenAvailable() {
        // Same early-ramp scenario, but the production app HAS history (~14×). During
        // warm-up we show the sane historical estimate, not the ramp extrapolation.
        // Predicted wall = 16245 / 14 ≈ 1160s; minus 360 elapsed ≈ 800s ≈ 13 min.
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 16245,
            realtimeRatio: 14,
            elapsed: 360,
            latestSegmentEnd: 41
        )
        #expect(est.remaining == "about 13 min left")
    }

    @Test
    func observedRateDrivesRemainingOnceCoverageIsEstablished() {
        // Past the warm-up guard (coverage ≥ 5%, elapsed ≥ 20s) the observed decode rate
        // drives the ETA even against a wildly optimistic historical ratio.
        // 30 audio-s / 40 wall-s = 0.75×; 70 audio-s left → ~93s → "about 2 min left".
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 100,
            realtimeRatio: 100,       // absurdly optimistic vs this run's actual pace
            elapsed: 40,
            latestSegmentEnd: 30
        )
        #expect(est.remaining == "about 2 min left")
        // The bar's fraction takes the time baseline here (0.99): when a run is far SLOWER
        // than history the estimate over-reports and pins near done — the accepted trade
        // for guaranteeing the bar animates on the common (normal-speed) run.
        #expect(est.progress == 0.99)
    }

    // MARK: - Historical realtime-ratio estimate (non-streaming engines)

    @Test
    func historyEstimateWhenNoSegments() {
        // 100s audio at 4× realtime → predicted 25s wall; 10s elapsed → 40%.
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 100,
            realtimeRatio: 4,
            elapsed: 10,
            latestSegmentEnd: nil
        )
        #expect(est.progress == 0.4)
        #expect(est.remaining == "about 15s left")
    }

    @Test
    func historyEstimateClampsBelowOneWhenOverrunning() {
        // Predicted 25s but already 30s elapsed → clamp at 0.99, "almost done".
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 100,
            realtimeRatio: 4,
            elapsed: 30,
            latestSegmentEnd: nil
        )
        #expect(est.progress == 0.99)
        #expect(est.remaining == "almost done")
    }

    @Test
    func noSignalReturnsIndeterminate() {
        // No streamed segment and no history → nil progress (spinner), no label.
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 100,
            realtimeRatio: nil,
            elapsed: 10,
            latestSegmentEnd: nil
        )
        #expect(est.progress == nil)
        #expect(est.remaining == nil)
    }

    @Test
    func zeroAudioDurationIsIndeterminate() {
        let est = TranscriptionProgressEstimate.compute(
            audioDuration: 0,
            realtimeRatio: 4,
            elapsed: 10,
            latestSegmentEnd: nil
        )
        #expect(est.progress == nil)
    }

    // MARK: - Remaining-time formatting

    @Test
    func formatRemainingBuckets() {
        #expect(TranscriptionProgressEstimate.formatRemaining(2) == "almost done")
        #expect(TranscriptionProgressEstimate.formatRemaining(-5) == "almost done")
        #expect(TranscriptionProgressEstimate.formatRemaining(30) == "about 30s left")
        #expect(TranscriptionProgressEstimate.formatRemaining(59) == "about 59s left")
        #expect(TranscriptionProgressEstimate.formatRemaining(90) == "about 2 min left")
        #expect(TranscriptionProgressEstimate.formatRemaining(600) == "about 10 min left")
    }

    @Test
    func formatRemainingRoundsSingleMinute() {
        // 61s rounds to 1 minute → the singular phrasing.
        #expect(TranscriptionProgressEstimate.formatRemaining(61) == "about 1 min left")
    }
}
