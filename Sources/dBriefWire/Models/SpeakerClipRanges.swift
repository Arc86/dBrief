import Foundation

/// Pure mapping from diarized segments to per-speaker concatenated sample
/// ranges, for feeding single-speaker audio into a voice-embedding extractor.
public enum SpeakerClipRanges {
    /// Per-speaker sample ranges. Groups segments by their non-nil `speaker`,
    /// converts each `[start, end]` (seconds) to a `Range<Int>` of sample
    /// indices clamped to `0..<totalSamples`, drops zero-length ranges, and
    /// omits any speaker whose total selected duration is below `minSeconds`.
    public static func build(
        segments: [TranscriptionResult.Segment],
        totalSamples: Int,
        sampleRate: Int = 16000,
        minSeconds: Double = 1.5
    ) -> [String: [Range<Int>]] {
        var ranges: [String: [Range<Int>]] = [:]
        for seg in segments {
            guard let id = seg.speaker else { continue }
            let lo = max(0, Int(seg.start * Double(sampleRate)))
            let hi = min(totalSamples, Int(seg.end * Double(sampleRate)))
            guard hi > lo else { continue }
            ranges[id, default: []].append(lo..<hi)
        }
        let minSamples = Int(minSeconds * Double(sampleRate))
        return ranges.filter { _, rs in
            rs.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } >= minSamples
        }
    }
}
