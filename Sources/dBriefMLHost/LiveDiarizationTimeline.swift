import Foundation
import dBriefWire

struct LiveDiarizationChunk: Sendable {
    let frameCount: Int
    let numSpeakers: Int
    let probabilities: [Float]
    init(frameCount: Int, numSpeakers: Int = 8, probabilities: [Float]) {
        self.frameCount = frameCount; self.numSpeakers = numSpeakers; self.probabilities = probabilities
    }
}

struct LiveDiarizationFrame: Sendable {
    let scope: LiveLaneScope
    let contextID: UUID
    let streamSamples: LiveSampleRange
    let samples: LiveSampleRange
    let meeting: LiveMeetingRange?
    let activity: [Float]
}

/// At most 64 pieces, one per retained epoch. Ordinary packets coalesce.
/// PCM is concatenated without synthetic pause silence; recorded time is piecewise.
struct LiveDiarizationTimeline: Sendable {
    static let maximumEpochs = 64
    static let maximumMappedFrames = 2_048
    private struct Piece: Sendable {
        let scope: LiveLaneScope
        let streamStart: Int64
        var count: Int64
        let meetingStart: Int64?
        var streamEnd: Int64 { streamStart + count }
        var meetingEnd: Int64? { meetingStart.map { $0 + count * 62_500 } }
    }
    let identity: LiveSessionIdentity
    let source: LiveSource
    let contextID: UUID
    let preset: LiveDiarizationPreset
    private(set) var scope: LiveLaneScope
    private(set) var streamEnd: Int64 = 0
    private(set) var frameEnd: Int64 = 0
    private(set) var sourceEnd: Int64 = 0
    private var epochs: Set<UUID>
    private var pieces: [Piece] = []
    private var lastKnownMeetingEnd: Int64?
    var epochCount: Int { epochs.count }
    var pieceCount: Int { pieces.count }
    var pendingSamples: Int64 { max(0, streamEnd - frameEnd * 160) }

    init(scope: LiveLaneScope, contextID: UUID, preset: LiveDiarizationPreset) throws {
        guard scope.source.isCaptureSource else { throw LiveDiarizationSession.Failure.invalidConfiguration }
        identity = scope.identity; source = scope.source; self.contextID = contextID; self.preset = preset
        self.scope = scope; epochs = [scope.epochID]
    }

    mutating func resume(previous: LiveLaneScope, next: LiveLaneScope) throws {
        guard previous == scope, next.identity == identity, next.source == source else { throw LiveDiarizationSession.Failure.staleScope }
        guard !epochs.contains(next.epochID) else { throw LiveDiarizationSession.Failure.invalidInput }
        guard epochs.count < Self.maximumEpochs else { throw LiveDiarizationSession.Failure.capacity }
        epochs.insert(next.epochID); scope = next; sourceEnd = 0
    }

    mutating func admit(scope: LiveLaneScope, samples: [Float], start: Int64, meeting: LiveMeetingRange?) throws {
        guard scope == self.scope else { throw LiveDiarizationSession.Failure.staleScope }
        guard (1...3_200).contains(samples.count), samples.allSatisfy(\.isFinite), start == sourceEnd else {
            throw LiveDiarizationSession.Failure.invalidInput
        }
        let count = Int64(samples.count), stream = streamEnd.addingReportingOverflow(Int64(samples.count))
        let end = start.addingReportingOverflow(count)
        guard !stream.overflow, !end.overflow, stream.partialValue <= Int64.max - 320,
              stream.partialValue - frameEnd * 160 <= preset.pendingSampleLimit else { throw LiveDiarizationSession.Failure.capacity }
        if let meeting {
            guard meeting.isValid, meeting.endNanoseconds - meeting.startNanoseconds == count * 62_500,
                  lastKnownMeetingEnd.map({ meeting.startNanoseconds >= $0 }) ?? true else { throw LiveDiarizationSession.Failure.invalidInput }
        }
        if let previous = pieces.last, previous.scope == scope {
            guard previous.meetingEnd == meeting?.startNanoseconds else { throw LiveDiarizationSession.Failure.invalidInput }
            pieces[pieces.count - 1].count += count
        } else {
            guard pieces.count < Self.maximumEpochs else { throw LiveDiarizationSession.Failure.capacity }
            pieces.append(.init(scope: scope, streamStart: streamEnd, count: count, meetingStart: meeting?.startNanoseconds))
        }
        streamEnd = stream.partialValue; sourceEnd = end.partialValue
        if let meeting { lastKnownMeetingEnd = meeting.endNanoseconds }
    }

    mutating func map(_ chunks: [LiveDiarizationChunk], terminal: Bool) throws -> [LiveDiarizationFrame] {
        // Check the entire immutable result before constructing rows or advancing authority.
        guard chunks.count <= 64 else { throw LiveDiarizationSession.Failure.capacity }
        var count = 0
        for chunk in chunks {
            guard chunk.frameCount > 0, chunk.frameCount <= preset.core * 8, chunk.numSpeakers == 8,
                  chunk.probabilities.count == chunk.frameCount * 8,
                  chunk.probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw LiveDiarizationSession.Failure.invalidInput
            }
            count += chunk.frameCount
            guard count <= preset.maximumBatchFrames else { throw LiveDiarizationSession.Failure.capacity }
        }
        guard count + max(0, pieces.count - 1) <= Self.maximumMappedFrames else { throw LiveDiarizationSession.Failure.capacity }
        let frames = frameEnd.addingReportingOverflow(Int64(count))
        guard !frames.overflow, frames.partialValue <= Int64.max / 160,
              frames.partialValue * 160 <= streamEnd + (terminal ? 320 : 0) else { throw LiveDiarizationSession.Failure.invalidInput }
        var rows: [LiveDiarizationFrame] = [], cursor = frameEnd, pieceIndex = 0
        for chunk in chunks {
            for row in 0..<chunk.frameCount {
                let start = cursor * 160, end = min(streamEnd, start + 160)
                cursor += 1
                guard start < end else { continue } // Native center padding is not evidence.
                while pieceIndex < pieces.count && pieces[pieceIndex].streamEnd <= start { pieceIndex += 1 }
                var index = pieceIndex
                let activity = Array(chunk.probabilities[(row * 8)..<(row * 8 + 8)])
                while index < pieces.count && pieces[index].streamStart < end {
                    let piece = pieces[index], lo = max(start, piece.streamStart), hi = min(end, piece.streamEnd)
                    if lo < hi {
                        let first = lo - piece.streamStart, last = hi - piece.streamStart
                        let meeting = piece.meetingStart.map {
                            LiveMeetingRange(startNanoseconds: $0 + first * 62_500, endNanoseconds: $0 + last * 62_500)
                        }
                        rows.append(.init(scope: piece.scope, contextID: contextID, streamSamples: .init(start: lo, end: hi),
                            samples: .init(start: first, end: last), meeting: meeting, activity: activity))
                    }
                    index += 1
                }
            }
        }
        frameEnd = frames.partialValue
        return rows
    }

    func attaching(_ segment: CommittedLiveSegment, scope: LiveLaneScope) throws -> CommittedLiveSegment {
        guard scope.identity == identity, scope.source == source, segment.source == source, segment.id.epochID == scope.epochID,
              epochs.contains(scope.epochID), segment.diarizerContextID == nil || segment.diarizerContextID == contextID else {
            throw LiveDiarizationSession.Failure.staleScope
        }
        guard segment.isValid, let range = segment.range.samples,
              let piece = pieces.first(where: { $0.scope == scope }), range.end <= piece.count else { throw LiveDiarizationSession.Failure.invalidInput }
        if let meeting = segment.range.meeting {
            guard let origin = piece.meetingStart,
                  meeting.startNanoseconds == origin + range.start * 62_500,
                  meeting.endNanoseconds == origin + range.end * 62_500 else { throw LiveDiarizationSession.Failure.invalidInput }
        }
        return .init(id: segment.id, source: segment.source, range: segment.range, text: segment.text, words: segment.words,
            language: segment.language, diarizerContextID: contextID)
    }
}
