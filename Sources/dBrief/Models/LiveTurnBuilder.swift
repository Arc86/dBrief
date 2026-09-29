import Foundation
import dBriefWire

/// Builds live-transcript display turns whose identities derive from each
/// segment's timing and speaker. Rebuilding after a new segment — or from a
/// freshly mapped array — keeps existing rows' ids, so `List` updates rows in
/// place instead of replacing all of them (the live-view flicker).
enum LiveTurnBuilder {
    static func turns(from segments: [LiveTranscriptSegment]) -> [SpeakerTurn] {
        var used = Set<UUID>()
        let rich = segments.map { seg in
            var salt: UInt64 = 0
            var id = stableID(start: seg.start, end: seg.end, speaker: seg.speaker, salt: salt)
            while !used.insert(id).inserted {
                salt += 1
                id = stableID(start: seg.start, end: seg.end, speaker: seg.speaker, salt: salt)
            }
            return RichSegment(id: id, start: seg.start, end: seg.end, text: seg.text,
                               originalText: seg.text, speakerId: seg.speaker)
        }
        return RichTranscript(segments: rich).speakerTurns()
    }

    /// Deterministic within and across runs: start bits fill the high half,
    /// end bits mixed with a stable speaker hash (and a de-dup salt) the low half.
    static func stableID(start: Double, end: Double, speaker: String?, salt: UInt64) -> UUID {
        let high = start.bitPattern.bigEndian
        let low = (end.bitPattern ^ fnv1a(speaker ?? "") ^ (salt &* 0x9E37_79B9_7F4A_7C15)).bigEndian
        let b = withUnsafeBytes(of: high, Array.init) + withUnsafeBytes(of: low, Array.init)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// FNV-1a — stable across launches, unlike `Hasher`.
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
