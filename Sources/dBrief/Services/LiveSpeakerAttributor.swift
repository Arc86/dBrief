import Foundation
import dBriefWire

/// Pure evaluation of a bounded, already mapped activity window. A future
/// serial producer owns native state, input accounting and acoustic qualification.
/// No posterior history, task or model is retained by this value.
struct LiveSpeakerAttributor: Sendable {
    static let maximumFrames = 2_048
    static let maximumWords = 512
    static let maximumRecordedRanges = 64
    static let maximumWindowNanoseconds: Int64 = 30_000_000_000
    enum Failure: Error, Equatable { case invalidInput, wrongScope, capacity }
    struct Policy: Sendable {
        /// Nil until the exact source/preset/acoustic mapping is qualified.
        let acousticQualificationID: UUID?
        let activityThreshold: Double
        let separationMargin: Double
        init(acousticQualificationID: UUID? = nil, activityThreshold: Double = 0.5, separationMargin: Double = 0.15) throws {
            guard activityThreshold.isFinite, activityThreshold > 0, activityThreshold <= 1,
                  separationMargin.isFinite, separationMargin > 0, separationMargin <= 1 else { throw Failure.invalidInput }
            self.acousticQualificationID = acousticQualificationID
            self.activityThreshold = activityThreshold; self.separationMargin = separationMargin
        }
    }
    struct Frame: Sendable {
        let meeting: LiveMeetingRange
        /// Eight independent activity probabilities; this is not a simplex.
        let activity: [Double]
    }
    struct Window: Sendable {
        let identity: LiveSessionIdentity
        let source: LiveSource
        let contextID: UUID
        /// Explicit piecewise observed audio. Padding/pauses are not observations.
        let recorded: [LiveMeetingRange]
        let frames: [Frame]
    }
    enum Timing: Sendable {
        case emission(wordIndex: Int)
        /// Separate acoustic provenance, never inferred from decoder confidence.
        case acoustic(wordIndex: Int, meeting: LiveMeetingRange, qualificationID: UUID)
    }
    struct Batch: Sendable {
        let identity: LiveSessionIdentity
        let source: LiveSource
        let contextID: UUID
        let annotations: [LiveSpeakerAnnotation]
        let coverage: [LiveAttributionCoverage]
    }
    private struct Acoustic { let meeting: LiveMeetingRange; let qualificationID: UUID }
    private struct Decision { let assignment: LiveSpeakerAnnotation.Assignment; let status: LiveAttributionCoverage.Status }
    let identity: LiveSessionIdentity
    let source: LiveSource
    let contextID: UUID
    let policy: Policy
    init(identity: LiveSessionIdentity, source: LiveSource, contextID: UUID, policy: Policy) throws {
        guard source.isCaptureSource else { throw Failure.wrongScope }
        self.identity = identity; self.source = source; self.contextID = contextID; self.policy = policy
    }

    func evaluate(_ segment: CommittedLiveSegment, timings: [Timing], window: Window) throws -> Batch {
        guard window.identity == identity, window.source == source, window.contextID == contextID,
              segment.source == source, segment.diarizerContextID == contextID else { throw Failure.wrongScope }
        guard window.frames.count <= Self.maximumFrames, window.recorded.count <= Self.maximumRecordedRanges,
              segment.words.count <= Self.maximumWords, timings.count <= Self.maximumWords else { throw Failure.capacity }
        guard segment.isValid else { throw Failure.invalidInput }
        try validateRanges(window.recorded)
        try validateRanges(window.frames.map(\.meeting))
        var minimum: Int64?, maximum: Int64 = 0
        for range in window.recorded + window.frames.map(\.meeting) + (segment.range.meeting.map { [$0] } ?? []) {
            minimum = min(minimum ?? range.startNanoseconds, range.startNanoseconds)
            maximum = max(maximum, range.endNanoseconds)
        }
        if let minimum, maximum - minimum > Self.maximumWindowNanoseconds { throw Failure.capacity }
        guard window.frames.allSatisfy({ frame in
            frame.activity.count == 8 && frame.activity.allSatisfy { $0.isFinite && (0...1).contains($0) }
        }) else { throw Failure.invalidInput }
        var acoustic: [Int: Acoustic] = [:], previousWord = -1
        var previousAcousticEnd: Int64?
        for timing in timings {
            let index: Int
            switch timing {
            case .emission(let word): index = word
            case .acoustic(let word, let meeting, let qualification):
                index = word
                guard let whole = segment.range.meeting, meeting.isValid,
                      meeting.startNanoseconds >= whole.startNanoseconds, meeting.endNanoseconds <= whole.endNanoseconds,
                      previousAcousticEnd.map({ meeting.startNanoseconds >= $0 }) ?? true else { throw Failure.invalidInput }
                previousAcousticEnd = meeting.endNanoseconds
                acoustic[word] = .init(meeting: meeting, qualificationID: qualification)
            }
            guard index > previousWord, segment.words.indices.contains(index) else { throw Failure.invalidInput }
            previousWord = index
        }

        // Intersections are sorted/disjoint and at most frames + recorded ranges.
        // Array values share the original immutable probability rows, not copies.
        let observed = clippedFrames(window)
        var annotations: [LiveSpeakerAnnotation] = [], coverage: [LiveAttributionCoverage] = []
        var cursor = segment.range.meeting?.startNanoseconds
        if segment.words.isEmpty { annotations.append(.init(segmentID: segment.id, assignment: .unknown)) }
        for word in segment.words.indices {
            var decision = Decision(assignment: .unknown, status: .unknown)
            if let span = acoustic[word] {
                if let qualification = policy.acousticQualificationID, span.qualificationID == qualification {
                    decision = evaluateSpan(span.meeting, observed: observed)
                }
                if let cursor, cursor < span.meeting.startNanoseconds {
                    appendCoverage(.init(startNanoseconds: cursor, endNanoseconds: span.meeting.startNanoseconds), .unknown, to: &coverage)
                }
                appendCoverage(span.meeting, decision.status, to: &coverage)
                cursor = span.meeting.endNanoseconds
            }
            annotations.append(.init(segmentID: segment.id, wordIndex: word, assignment: decision.assignment))
        }
        if let whole = segment.range.meeting, let cursor {
            if cursor < whole.endNanoseconds { appendCoverage(.init(startNanoseconds: cursor, endNanoseconds: whole.endNanoseconds), .unknown, to: &coverage) }
        } else { coverage.append(.init(source: source, contextID: contextID, meeting: nil, status: .unknown)) }
        return .init(identity: identity, source: source, contextID: contextID, annotations: annotations, coverage: coverage)
    }

    private func validateRanges(_ ranges: [LiveMeetingRange]) throws {
        var previousEnd: Int64?
        for range in ranges {
            guard range.isValid, previousEnd.map({ range.startNanoseconds >= $0 }) ?? true else { throw Failure.invalidInput }
            previousEnd = range.endNanoseconds
        }
    }
    private func clippedFrames(_ window: Window) -> [Frame] {
        var result: [Frame] = [], recordIndex = 0
        for frame in window.frames {
            while recordIndex < window.recorded.count && window.recorded[recordIndex].endNanoseconds <= frame.meeting.startNanoseconds { recordIndex += 1 }
            var index = recordIndex
            while index < window.recorded.count && window.recorded[index].startNanoseconds < frame.meeting.endNanoseconds {
                let range = window.recorded[index]
                let start = max(frame.meeting.startNanoseconds, range.startNanoseconds), end = min(frame.meeting.endNanoseconds, range.endNanoseconds)
                if start < end { result.append(.init(meeting: .init(startNanoseconds: start, endNanoseconds: end), activity: frame.activity)) }
                if range.endNanoseconds >= frame.meeting.endNanoseconds { break }
                index += 1
            }
            recordIndex = index
        }
        return result
    }
    private func evaluateSpan(_ span: LiveMeetingRange, observed: [Frame]) -> Decision {
        var cursor = span.startNanoseconds
        var assignment: LiveSpeakerAnnotation.Assignment?, homogeneous = true
        for frame in observed {
            if frame.meeting.startNanoseconds >= span.endNanoseconds { break }
            let start = max(frame.meeting.startNanoseconds, span.startNanoseconds), end = min(frame.meeting.endNanoseconds, span.endNanoseconds)
            if start >= end { continue }
            guard start == cursor else { return .init(assignment: .unknown, status: .unavailable) }
            let current = frameAssignment(frame.activity)
            if let assignment { if assignment != current { homogeneous = false } }
            else { assignment = current }
            cursor = end
        }
        guard cursor == span.endNanoseconds else { return .init(assignment: .unknown, status: .unavailable) }
        guard homogeneous, let assignment else { return .init(assignment: .unknown, status: .unknown) }
        switch assignment {
        case .track: return .init(assignment: assignment, status: .resolved)
        case .overlap: return .init(assignment: assignment, status: .overlap)
        case .unknown: return .init(assignment: .unknown, status: .unknown)
        }
    }
    private func frameAssignment(_ values: [Double]) -> LiveSpeakerAnnotation.Assignment {
        let active = values.indices.filter { values[$0] >= policy.activityThreshold }
        if active.count > 1 { return .overlap(active.map(track)) }
        guard let slot = active.first else { return .unknown }
        let competitor = values.indices.filter { $0 != slot }.map { values[$0] }.max() ?? 0
        guard values[slot] - competitor >= policy.separationMargin else { return .unknown }
        return .track(track(slot))
    }
    private func track(_ slot: Int) -> SpeakerTrackKey {
        .init(captureSessionID: identity.captureSessionID, source: source, contextID: contextID, slot: slot)
    }
    private func appendCoverage(_ meeting: LiveMeetingRange, _ status: LiveAttributionCoverage.Status, to values: inout [LiveAttributionCoverage]) {
        if let last = values.last, last.status == status, let previous = last.meeting, previous.endNanoseconds == meeting.startNanoseconds {
            values[values.count - 1] = .init(source: source, contextID: contextID,
                meeting: .init(startNanoseconds: previous.startNanoseconds, endNanoseconds: meeting.endNanoseconds), status: status)
        } else { values.append(.init(source: source, contextID: contextID, meeting: meeting, status: status)) }
    }
}
