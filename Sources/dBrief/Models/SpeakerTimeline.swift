import Foundation

/// A clipped segment interval retaining the transcript's stable speaker ID.
/// The empty ID represents speech with unknown speaker attribution.
struct SpeakerTimeRange: Equatable, Sendable {
    let start: Double
    let end: Double
    let speakerID: String
}

/// Pure time-based speaker lookup for waveform samples and playback UI.
enum SpeakerTimeline {
    static func normalize(_ segments: [RichSegment], duration: Double) -> [SpeakerTimeRange] {
        guard duration.isFinite, duration > 0 else { return [] }

        return segments.compactMap { segment in
            guard segment.start.isFinite,
                  segment.end.isFinite,
                  segment.start < segment.end
            else {
                return nil
            }

            let start = max(0, segment.start)
            let end = min(duration, segment.end)
            guard start < end else { return nil }

            let rawSpeakerID = segment.speakerId ?? ""
            let speakerID = rawSpeakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : rawSpeakerID

            return SpeakerTimeRange(
                start: start,
                end: end,
                speakerID: speakerID
            )
        }
        .sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.speakerID < $1.speakerID
        }
    }

    /// Returns an ID only when every active interval names the same real speaker.
    /// Ranges are half-open: an interval is active at `start`, never at `end`.
    static func speakerID(at time: Double, in ranges: [SpeakerTimeRange]) -> String? {
        guard time.isFinite else { return nil }

        var activeSpeaker: String?
        for range in ranges where range.start.isFinite && range.end.isFinite
            && range.start < range.end && range.start <= time && time < range.end {
            if Self.isUnknown(range.speakerID) { return nil }
            if let activeSpeaker, activeSpeaker != range.speakerID { return nil }
            activeSpeaker = range.speakerID
        }
        return activeSpeaker
    }

    /// Samples the centre of each equally spaced waveform bar. Sorting interval
    /// events once keeps this O(S log S + N), instead of scanning S ranges per bar.
    static func sampledSpeakerIDs(
        in ranges: [SpeakerTimeRange],
        duration: Double,
        count: Int
    ) -> [String?] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }

        let intervals = ranges.compactMap { range -> SpeakerTimeRange? in
            guard range.start.isFinite, range.end.isFinite, range.start < range.end else { return nil }
            let start = max(0, range.start)
            let end = min(duration, range.end)
            guard start < end else { return nil }
            return SpeakerTimeRange(start: start, end: end, speakerID: range.speakerID)
        }

        var events: [Event] = []
        events.reserveCapacity(intervals.count * 2)
        for range in intervals {
            events.append(Event(time: range.start, speakerID: range.speakerID, isStart: true))
            events.append(Event(time: range.end, speakerID: range.speakerID, isStart: false))
        }
        events.sort {
            if $0.time != $1.time { return $0.time < $1.time }
            return !$0.isStart && $1.isStart
        }

        var results: [String?] = []
        results.reserveCapacity(count)
        var activeCounts: [String: Int] = [:]
        var eventIndex = 0

        for index in 0..<count {
            let time = duration * (Double(index) + 0.5) / Double(count)
            while eventIndex < events.count, events[eventIndex].time <= time {
                let event = events[eventIndex]
                if event.isStart {
                    activeCounts[event.speakerID, default: 0] += 1
                } else if let current = activeCounts[event.speakerID] {
                    if current <= 1 {
                        activeCounts.removeValue(forKey: event.speakerID)
                    } else {
                        activeCounts[event.speakerID] = current - 1
                    }
                }
                eventIndex += 1
            }

            if activeCounts.count == 1,
               let (speakerID, count) = activeCounts.first,
               count > 0,
               !Self.isUnknown(speakerID) {
                results.append(speakerID)
            } else {
                results.append(nil)
            }
        }
        return results
    }

    private static func isUnknown(_ speakerID: String) -> Bool {
        speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct Event {
        let time: Double
        let speakerID: String
        let isStart: Bool
    }
}
