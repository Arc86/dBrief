import Foundation

/// Pure, unit-tested math for the transcription progress bar + "time left" label
/// shown during processing.
///
/// Two signals feed it:
///  1. **True segment coverage** — when the engine streams progressive segments
///     (WhisperKit), the furthest-decoded segment end divided by the audio duration
///     is an exact progress fraction, and once enough audio has been covered the
///     observed audio-per-wall-second rate gives an accurate remaining estimate.
///  2. **Historical realtime ratio** — the model's average realtime ratio
///     (audio-seconds per wall-second) recorded in `ModelPerformanceStore`, used
///     both for engines that transcribe in one opaque call (Parakeet, Apple Speech,
///     remote) and as the *warm-up* estimate for streaming engines before observed
///     coverage is trustworthy.
///
/// The remaining-time label deliberately does **not** extrapolate from the observed
/// rate during the startup ramp: WhisperKit's model load + first-chunk latency, plus
/// out-of-order VAD workers, make the early `covered / elapsed` rate a tiny fraction
/// of steady state — extrapolating it linearly across a multi-hour file yields absurd
/// ETAs (e.g. "2366 min left"). Instead it stays on the historical ratio (or shows no
/// label at all, when there's no history — e.g. a fresh install) until coverage is
/// established, then switches to the now-stable observed rate.
///
/// Returns `nil` progress when no signal is usable so the caller shows an
/// indeterminate spinner instead of a fake bar.
enum TranscriptionProgressEstimate {
    /// Minimum audio-coverage fraction before the observed rate is trusted for the
    /// remaining-time label (below this the startup ramp dominates the rate).
    static let minCoverageForRateEstimate: Double = 0.05
    /// Minimum wall-seconds transcribing before the observed rate is trusted (guards
    /// short files whose first segment lands in the first second or two).
    static let minElapsedForRateEstimate: TimeInterval = 20

    /// - Parameters:
    ///   - audioDuration: length of the audio being transcribed, in seconds.
    ///   - realtimeRatio: historical audio-seconds transcribed per wall-second for
    ///     this model, or `nil` when there's no history.
    ///   - elapsed: wall-clock seconds since transcription (not download/load) began.
    ///   - latestSegmentEnd: furthest-decoded segment end (the caller should pass the
    ///     max end across streamed segments, not the last-appended one — VAD workers
    ///     stream out of order), or `nil` when nothing has streamed yet.
    /// - Returns: `progress` clamped to `0...0.99` (never 1.0 — the step's own
    ///   completion drives the final state), and a human-readable `remaining` label
    ///   (`nil` when no estimate is trustworthy yet).
    static func compute(
        audioDuration: TimeInterval,
        realtimeRatio: Double?,
        elapsed: TimeInterval,
        latestSegmentEnd: TimeInterval?
    ) -> (progress: Double?, remaining: String?) {
        guard audioDuration > 0 else { return (nil, nil) }

        // --- Time-based estimate from the (historical or default) realtime ratio ---
        // A smooth baseline the bar can always ride, so it never sits at zero while the
        // engine works. nil only when there's genuinely no ratio (the pure-function
        // defensive path; the live caller always supplies a per-engine fallback).
        var timeFrac: Double?
        var historyRemaining: String?
        if let ratio = realtimeRatio, ratio > 0 {
            let predictedWall = audioDuration / ratio
            if predictedWall > 0 {
                timeFrac = min(0.99, max(0, elapsed / predictedWall))
                historyRemaining = formatRemaining(predictedWall - elapsed)
            }
        }

        // --- Coverage-based estimate from streamed segments ---
        // The furthest-decoded segment end is a hard LOWER BOUND on true progress. It is
        // NOT an upper bound: engines deliver segments late/bursty (observed: WhisperKit
        // batching a multi-hour in-memory file), so a small covered fraction does not mean
        // little has been decoded — which is why coverage alone must not pull the bar down.
        var coverageFrac: Double?
        var observedRemaining: String?
        if let end = latestSegmentEnd, end > 0 {
            coverageFrac = min(0.99, max(0, end / audioDuration))
            // Only trust the observed rate for the ETA once enough audio is covered and
            // enough time has passed; before that the startup ramp extrapolates into an
            // absurd label, so we defer to the historical/ratio estimate instead.
            let rateIsTrustworthy = (coverageFrac ?? 0) >= minCoverageForRateEstimate
                && elapsed >= minElapsedForRateEstimate
            if rateIsTrustworthy {
                let rate = end / elapsed // observed audio-sec per wall-sec
                if rate > 0 {
                    observedRemaining = formatRemaining((audioDuration - end) / rate)
                }
            }
        }

        // Progress = the further-along of the two signals. The time baseline keeps the bar
        // moving when coverage lags; coverage snaps it forward when segments arrive faster
        // than the ratio predicted. (Trade-off: a run much slower than history over-reports
        // and pins at 99% — accepted, since a bar that stalls near zero on a normal run is
        // the worse failure.) nil only when neither signal exists → indeterminate spinner.
        let progress = [timeFrac, coverageFrac].compactMap { $0 }.max()

        // Remaining label: the observed decode rate once coverage is established, else the
        // ratio-based estimate; nil when neither is trustworthy (no bogus ETA).
        return (progress, observedRemaining ?? historyRemaining)
    }

    /// Format a remaining-seconds estimate as a short, non-jittery label.
    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 5 { return "almost done" }
        if clamped < 60 {
            let s = Int(clamped.rounded())
            return "about \(s)s left"
        }
        let minutes = Int((clamped / 60).rounded())
        return minutes <= 1 ? "about 1 min left" : "about \(minutes) min left"
    }
}
