import Foundation
import dBriefWire

/// Full committed history, independent of the smaller evidence view through the
/// shared cutoff. No partial hypotheses, decoder cache or resumable native state.
struct LiveTranscriptCheckpoint: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var version = Self.currentVersion
    let identity: LiveSessionIdentity
    let revision: UInt64
    let annotationRevision: UInt64
    let epochs: [LiveEpoch]
    let lanes: [LiveLaneWatermarks]
    let segments: [CommittedLiveSegment]
    let coverage: [LiveCoverageInterval]
    let captureLosses: [LiveCaptureRawLoss]
    let annotations: [LiveSpeakerAnnotation]
    let attributionCoverage: [LiveAttributionCoverage]
    let cutoffNanoseconds: Int64?
    let finalPublication: TranscriptSourcePublication?
    let retiredPublicationIDs: [UUID]
    var bindingGeneration: UUID?

    enum Failure: Error { case unsupportedVersion, invalidCheckpoint, tooManyObservers }

    func validate() throws {
        guard version == Self.currentVersion else { throw Failure.unsupportedVersion }
        guard epochs.count <= 100_000, segments.count <= 100_000, coverage.count <= 200_000,
              captureLosses.count <= 100_000, annotations.count <= 100_000, attributionCoverage.count <= 100_000,
              lanes.count <= 2, retiredPublicationIDs.count <= 100_000, annotationRevision <= revision,
              cutoffNanoseconds.map({ $0 >= 0 }) ?? true,
              Set(epochs.map(\.id)).count == epochs.count, Set(lanes.map { $0.epoch.source }).count == lanes.count,
              Set(segments.map(\.id)).count == segments.count, Set(captureLosses.map(\.id)).count == captureLosses.count,
              Set(retiredPublicationIDs).count == retiredPublicationIDs.count,
              epochs.allSatisfy({ $0.source.isCaptureSource && !$0.engineRevision.isEmpty && $0.engineRevision.utf8.count <= 256 &&
                  !$0.language.isEmpty && $0.language.utf8.count <= 32 && ($0.meetingOriginNanoseconds.map({ $0 >= 0 }) ?? true) }),
              captureLosses.allSatisfy(\.isValid) else { throw Failure.invalidCheckpoint }
        let byEpoch = Dictionary(uniqueKeysWithValues: epochs.map { ($0.id, $0) })
        var latestEpochs: [LiveSource: LiveEpoch] = [:]
        for epoch in epochs { latestEpochs[epoch.source] = epoch }
        guard latestEpochs.count == lanes.count else { throw Failure.invalidCheckpoint }
        let byLane = Dictionary(uniqueKeysWithValues: lanes.map { ($0.epoch.source, $0) })
        for lane in lanes {
            let p = lane.progress
            guard latestEpochs[lane.epoch.source] == lane.epoch, p.consumedSampleEnd >= 0,
                  p.consumedSampleEnd <= p.effectiveASRConsumedSampleEnd, p.effectiveASRConsumedSampleEnd <= p.admittedSampleEnd,
                  p.admittedSampleEnd <= p.capturedSampleEnd, lane.settledSampleEnd >= 0, lane.settledSampleEnd <= p.capturedSampleEnd,
                  lane.settledMeetingNanoseconds == Self.meeting(lane.settledSampleEnd, epoch: lane.epoch),
                  lane.epoch.meetingOriginNanoseconds == nil || Self.meeting(p.capturedSampleEnd, epoch: lane.epoch) != nil else {
                throw Failure.invalidCheckpoint
            }
        }
        let bySegment = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        for segment in segments {
            guard segment.isValid, let epoch = byEpoch[segment.id.epochID], epoch.source == segment.source,
                  let samples = segment.range.samples, samples.isValid,
                  segment.range.meeting == Self.range(samples, epoch: epoch) else { throw Failure.invalidCheckpoint }
        }
        var settled: [UUID: Int64] = [:]
        var committed = Set<LiveSegmentID>()
        var qualified: [LiveSource: Int64] = [:]
        var saved: [LiveSavedAudioSlice.Destination: LiveSavedAudioSlice] = [:]
        for interval in coverage {
            guard interval.range.isValid, interval.source.isCaptureSource else { throw Failure.invalidCheckpoint }
            if let epochID = interval.epochID {
                guard let epoch = byEpoch[epochID], epoch.source == interval.source, let samples = interval.range.samples,
                      samples.start == (settled[epochID] ?? 0),
                      interval.range.meeting == Self.range(samples, epoch: epoch),
                      epoch.meetingOriginNanoseconds == nil || interval.range.meeting != nil else { throw Failure.invalidCheckpoint }
                settled[epochID] = samples.end
                if let lane = byLane[interval.source], lane.epoch.id == epochID {
                    let requiresConsumption = interval.kind == .committed || interval.kind == .processedSilence
                    guard samples.end <= lane.settledSampleEnd,
                          !requiresConsumption || samples.end <= lane.progress.effectiveASRConsumedSampleEnd else {
                        throw Failure.invalidCheckpoint
                    }
                }
            } else {
                guard case .gap = interval.kind, interval.range.samples == nil, interval.range.meeting != nil,
                      interval.range.savedAudio.isEmpty else { throw Failure.invalidCheckpoint }
            }
            if let meeting = interval.range.meeting {
                guard meeting.startNanoseconds == (qualified[interval.source] ?? 0) else { throw Failure.invalidCheckpoint }
                qualified[interval.source] = meeting.endNanoseconds
            }
            for slice in interval.range.savedAudio {
                guard slice.samples != nil, slice.destination == .track(interval.source) else { throw Failure.invalidCheckpoint }
                if let prior = saved[slice.destination] {
                    guard prior.sampleRate == slice.sampleRate, slice.startFrame >= prior.startFrame + prior.frameCount else {
                        throw Failure.invalidCheckpoint
                    }
                }
                saved[slice.destination] = slice
            }
            if interval.kind == .committed {
                guard let id = interval.committedSegmentID, let segment = bySegment[id],
                      committed.insert(id).inserted,
                      segment.range == interval.range, segment.source == interval.source, id.epochID == interval.epochID else {
                    throw Failure.invalidCheckpoint
                }
            } else if interval.committedSegmentID != nil { throw Failure.invalidCheckpoint }
        }
        guard committed == Set(bySegment.keys), lanes.allSatisfy({ (settled[$0.epoch.id] ?? 0) == $0.settledSampleEnd }) else {
            throw Failure.invalidCheckpoint
        }
        // Empty aligned epochs still establish a qualified origin through an
        // explicit preparation/restart gap. A later unaligned epoch does not
        // remove that historical proof or authorize silently missing coverage.
        for epoch in epochs {
            if let origin = epoch.meetingOriginNanoseconds {
                guard origin <= (qualified[epoch.source] ?? 0) else { throw Failure.invalidCheckpoint }
            }
        }
        for lane in lanes where lane.epoch.meetingOriginNanoseconds != nil {
            guard lane.settledMeetingNanoseconds == (qualified[lane.epoch.source] ?? 0) else { throw Failure.invalidCheckpoint }
        }
        let participating = lanes.filter { ($0.availability == .active || $0.availability == .paused) && $0.epoch.meetingOriginNanoseconds != nil }
        if let frontier = participating.compactMap(\.settledMeetingNanoseconds).min() {
            guard cutoffNanoseconds == frontier else { throw Failure.invalidCheckpoint }
        } else if let cutoff = cutoffNanoseconds {
            // A removed/unaligned lane can leave the previous shared cutoff
            // frozen. Its qualified history or epoch origin must still prove it.
            let frontier = (epochs.compactMap(\.meetingOriginNanoseconds) + Array(qualified.values)).max()
            guard let frontier, cutoff <= frontier else { throw Failure.invalidCheckpoint }
        }
        try Self.validateAnnotations(annotations, segments: bySegment, identity: identity)
        guard attributionCoverage.allSatisfy({ $0.source.isCaptureSource && ($0.meeting?.isValid ?? true) }) else {
            throw Failure.invalidCheckpoint
        }
        if let publication = finalPublication {
            guard publication.identity == identity, publication.revision > 0, !retiredPublicationIDs.contains(publication.id),
                  publication.segments.count <= 100_000, Set(publication.segments.map(\.id)).count == publication.segments.count,
                  publication.segments.allSatisfy({ $0.source == .finalMix && $0.id.epochID == publication.id && $0.isValid &&
                      $0.range.samples == nil && $0.range.meeting == nil &&
                      $0.range.savedAudio.allSatisfy({ $0.samples == nil && $0.destination == .master }) }) else {
                throw Failure.invalidCheckpoint
            }
            try Self.validateAnnotations(publication.annotations,
                segments: Dictionary(uniqueKeysWithValues: publication.segments.map { ($0.id, $0) }), identity: identity)
        }
    }

    static func validAnnotation(_ annotation: LiveSpeakerAnnotation, segment: CommittedLiveSegment, identity: LiveSessionIdentity) -> Bool {
        if let word = annotation.wordIndex, word < 0 || word >= segment.words.count { return false }
        func valid(_ key: SpeakerTrackKey) -> Bool {
            key.captureSessionID == identity.captureSessionID && key.source == segment.source &&
                key.contextID == segment.diarizerContextID && key.slot >= 0 && key.slot < (segment.source.isCaptureSource ? 8 : 256)
        }
        switch annotation.assignment {
        case .unknown: return true
        case .track(let key): return valid(key)
        case .overlap(let tracks): return (2...8).contains(tracks.count) && Set(tracks).count == tracks.count && tracks.allSatisfy(valid)
        }
    }
    private static func validateAnnotations(_ annotations: [LiveSpeakerAnnotation], segments: [LiveSegmentID: CommittedLiveSegment],
                                            identity: LiveSessionIdentity) throws {
        var keys = Set<String>()
        guard annotations.count <= 100_000 else { throw Failure.invalidCheckpoint }
        for annotation in annotations {
            guard let segment = segments[annotation.segmentID], validAnnotation(annotation, segment: segment, identity: identity),
                  keys.insert("\(annotation.segmentID):\(annotation.wordIndex ?? -1)").inserted else { throw Failure.invalidCheckpoint }
        }
    }
    private static func meeting(_ sample: Int64, epoch: LiveEpoch) -> Int64? {
        guard sample >= 0, let origin = epoch.meetingOriginNanoseconds else { return nil }
        let offset = sample.multipliedReportingOverflow(by: 62_500)
        guard !offset.overflow else { return nil }
        let sum = origin.addingReportingOverflow(offset.partialValue)
        return sum.overflow ? nil : sum.partialValue
    }
    private static func range(_ samples: LiveSampleRange, epoch: LiveEpoch) -> LiveMeetingRange? {
        guard let start = meeting(samples.start, epoch: epoch), let end = meeting(samples.end, epoch: epoch) else { return nil }
        return .init(startNanoseconds: start, endNanoseconds: end)
    }
}
