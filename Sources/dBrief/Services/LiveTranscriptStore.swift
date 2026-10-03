import Foundation
import dBriefWire

enum LiveStoreRejection: Error, Equatable {
    case wrongOwner, staleEpoch, outOfOrder, invalidRange, conflictingID, unsettledEpoch, closed, invalidAnnotation, stalePublication
}
enum LiveStoreAdmission: Equatable { case accepted, duplicate, rejected(LiveStoreRejection) }
enum LiveSnapshotSelection: Sendable {
    case committed, range(LiveMeetingRange), evidence([LiveSegmentID], includeUnaligned: Bool)
}

/// Validation, mutation and snapshot publication have no suspension points.
/// Native consumption never substitutes for contiguous settled evidence.
actor LiveTranscriptStore {
    private final class CaptureBinding: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: UUID?
        func bind(_ value: UUID, accepting: () -> Bool) -> Bool {
            lock.withLock {
                guard owner == nil else { return owner == value }
                guard accepting() else { return false }
                owner = value; return true
            }
        }
    }
    private nonisolated let captureBinding = CaptureBinding()
    /// One core can publish/retire this capture. Binding precedes async startup,
    /// even when a second factory supplied another ingress/preparation object.
    nonisolated func bindCaptureOwner(_ owner: UUID, accepting: () -> Bool) -> Bool {
        captureBinding.bind(owner,accepting: accepting)
    }

    private struct Lane {
        let epoch: LiveEpoch
        var availability: LiveSourceAvailability
        var progress = LiveLaneProgress(capturedSampleEnd: 0, admittedSampleEnd: 0, consumedSampleEnd: 0)
        var settled: Int64 = 0
        var meeting: Int64?
        var nextSequence: UInt64 = 0
        var lastEvent: LiveTranscriptEvent?
        var partial: LivePartial?
    }
    private struct AnnotationKey: Hashable { let segment: LiveSegmentID; let word: Int? }
    private struct AnnotationBatch: Equatable {
        let sequence: UInt64
        let annotations: [LiveSpeakerAnnotation]
        let coverage: [LiveAttributionCoverage]
    }
    private struct Diarizer {
        let id: UUID
        let meetingStart: Int64?
        let firstEpochOrder: Int
        let firstSample: Int64
        var nextSequence: UInt64 = 0
        var lastBatch: AnnotationBatch?
    }
    let identity: LiveSessionIdentity
    private let validity: RecordingDerivativeValidity
    private var lanes: [LiveSource: Lane] = [:]
    private var epochs: [UUID: LiveEpoch] = [:]
    private var epochOrder: [UUID: Int] = [:]
    private var qualifiedFrontiers: [LiveSource: Int64] = [:]
    private var segments: [LiveSegmentID: CommittedLiveSegment] = [:]
    private var coverage: [LiveCoverageInterval] = []
    private var captureLosses: [LiveCaptureRawLoss] = []
    private var captureLossIDs: [UUID: Int] = [:]
    private var diarizers: [LiveSource: Diarizer] = [:]
    private var knownDiarizers: [LiveSource: Set<UUID>] = [:]
    private var savedFrontiers: [LiveSavedAudioSlice.Destination: LiveSavedAudioSlice] = [:]
    private var annotations: [AnnotationKey: LiveSpeakerAnnotation] = [:]
    private var attributionCoverage: [LiveAttributionCoverage] = []
    private var finalPublication: TranscriptSourcePublication?
    private var retiredPublications: Set<UUID> = []
    private var revision: UInt64 = 0
    private var annotationRevision: UInt64 = 0
    private var lastKnownCutoff: Int64?
    private var isClosed = false

    init(identity: LiveSessionIdentity, validity: RecordingDerivativeValidity = RecordingDerivativeValidity()) {
        self.identity = identity; self.validity = validity
    }

    /// No mutation suspension points exist inside this shared validity lock.
    /// Retirement therefore linearizes before every later derivative write.
    private func mutate(_ body: () -> LiveStoreAdmission) -> LiveStoreAdmission {
        (try? validity.withValidResult(body)) ?? .rejected(.closed)
    }

    func checkEpoch(owner: LiveSessionIdentity, epoch: LiveEpoch) -> LiveStoreAdmission {
        mutate { validateEpoch(owner: owner,epoch: epoch) }
    }
    func beginEpoch(owner: LiveSessionIdentity, epoch: LiveEpoch) -> LiveStoreAdmission {
        mutate { beginEpochWhileValid(owner: owner,epoch: epoch) }
    }
    func admit(_ event: LiveTranscriptEvent) -> LiveStoreAdmission { mutate { admitWhileValid(event) } }
    func registerDiarizer(owner: LiveSessionIdentity, source: LiveSource, contextID: UUID) -> LiveStoreAdmission {
        mutate { registerDiarizerWhileValid(owner: owner,source: source,contextID: contextID) }
    }
    func annotate(owner: LiveSessionIdentity, source: LiveSource, contextID: UUID, sequence: UInt64,
                  annotations: [LiveSpeakerAnnotation], coverage: [LiveAttributionCoverage] = []) -> LiveStoreAdmission {
        mutate { annotateWhileValid(owner: owner,source: source,contextID: contextID,sequence: sequence,annotations: annotations,coverage: coverage) }
    }
    func close(owner: LiveSessionIdentity) -> LiveStoreAdmission { mutate { closeWhileValid(owner: owner) } }
    func publishFinal(_ publication: TranscriptSourcePublication) -> LiveStoreAdmission { mutate { publishFinalWhileValid(publication) } }
    func clearPartials(owner: LiveSessionIdentity, source: LiveSource? = nil) -> LiveStoreAdmission {
        mutate { clearPartialsWhileValid(owner: owner,source: source) }
    }
    func recordCaptureLoss(owner: LiveSessionIdentity, loss: LiveCaptureRawLoss) -> LiveStoreAdmission {
        mutate {
            guard owner == identity else { return .rejected(.wrongOwner) }
            guard !isClosed else { return .rejected(.closed) }
            guard loss.isValid else { return .rejected(.invalidRange) }
            if let index = captureLossIDs[loss.id] {
                return captureLosses[index] == loss ? .duplicate : .rejected(.conflictingID)
            }
            guard captureLosses.count < 100000, revision < .max else { return .rejected(.invalidRange) }
            captureLossIDs[loss.id] = captureLosses.count; captureLosses.append(loss)
            revision += 1
            return .accepted
        }
    }


    /// Read-only preflight; beginEpoch repeats this check at the actual write.
    private func validateEpoch(owner: LiveSessionIdentity, epoch: LiveEpoch) -> LiveStoreAdmission {
        guard owner == identity else { return .rejected(.wrongOwner) }
        guard !isClosed else { return .rejected(.closed) }
        guard epoch.source.isCaptureSource, !epoch.engineRevision.isEmpty, epoch.engineRevision.utf8.count <= 256,
              !epoch.language.isEmpty, epoch.language.utf8.count <= 32,
              epoch.meetingOriginNanoseconds.map({ $0 >= 0 }) ?? true, revision < .max else { return .rejected(.invalidRange) }
        if let known = epochs[epoch.id] {
            return known == epoch && lanes[epoch.source]?.epoch == epoch ? .duplicate : .rejected(.staleEpoch)
        }
        if let old = lanes[epoch.source] {
            guard old.settled == old.progress.capturedSampleEnd else { return .rejected(.unsettledEpoch) }
            if let origin = epoch.meetingOriginNanoseconds, let prior = old.meeting, origin < prior { return .rejected(.invalidRange) }
        }
        if let origin = epoch.meetingOriginNanoseconds, let cutoff = lastKnownCutoff, origin < cutoff { return .rejected(.invalidRange) }
        if let origin = epoch.meetingOriginNanoseconds, let prior = qualifiedFrontiers[epoch.source], origin < prior { return .rejected(.invalidRange) }
        return .accepted
    }

    private func beginEpochWhileValid(owner: LiveSessionIdentity, epoch: LiveEpoch) -> LiveStoreAdmission {
        let admission = validateEpoch(owner: owner,epoch: epoch)
        guard admission == .accepted else { return admission }
        if let origin = epoch.meetingOriginNanoseconds {
            let old = lanes[epoch.source], start = qualifiedFrontiers[epoch.source] ?? 0
            if origin > start {
                let reason: LiveGapReason = old == nil ? .preparation :
                    old?.epoch.meetingOriginNanoseconds == nil ? .unknownClock :
                    old?.availability == .disabled ? .disabled : old?.availability == .unavailable ? .unavailable : .engineRestart
                coverage.append(.init(epochID: nil, source: epoch.source,
                    range: .init(samples: nil, meeting: .init(startNanoseconds: start, endNanoseconds: origin)), kind: .gap(reason)))
            }
            qualifiedFrontiers[epoch.source] = origin
        }
        lanes[epoch.source] = Lane(epoch: epoch, availability: epoch.availability, meeting: epoch.meetingOriginNanoseconds)
        epochOrder[epoch.id] = epochs.count
        epochs[epoch.id] = epoch
        revision += 1
        refreshCutoff()
        return .accepted
    }

    private func admitWhileValid(_ event: LiveTranscriptEvent) -> LiveStoreAdmission {
        guard event.identity == identity else { return .rejected(.wrongOwner) }
        guard !isClosed else { return .rejected(.closed) }
        guard var lane = lanes[event.source], lane.epoch.id == event.epochID else { return .rejected(.staleEpoch) }
        // Validate embedded scope before replay checks. A payload from another
        // lane must never be acknowledged as this lane's successful duplicate.
        switch event.payload {
        case .committed(let segment):
            guard segment.id.epochID == event.epochID, segment.source == event.source else { return .rejected(.staleEpoch) }
        case .partial(let partial):
            guard partial.epochID == event.epochID, partial.source == event.source else { return .rejected(.staleEpoch) }
        case .settled(let interval):
            guard interval.epochID == event.epochID, interval.source == event.source else { return .rejected(.staleEpoch) }
        case .progress, .availability: break
        }
        if event.sequence < lane.nextSequence {
            if event == lane.lastEvent { return .duplicate }
            if case .committed(let segment) = event.payload, segments[segment.id] == segment { return .duplicate }
            return .rejected(.outOfOrder)
        }
        guard event.sequence == lane.nextSequence, event.sequence < .max else { return .rejected(.outOfOrder) }
        guard revision < .max else { return .rejected(.invalidRange) }
        var changed = false, result = LiveStoreAdmission.accepted
        var inserted: CommittedLiveSegment?, settled: LiveCoverageInterval?
        switch event.payload {
        case .progress(let progress):
            guard progress.consumedSampleEnd >= lane.progress.consumedSampleEnd,
                  progress.effectiveASRConsumedSampleEnd >= lane.progress.effectiveASRConsumedSampleEnd,
                  progress.admittedSampleEnd >= lane.progress.admittedSampleEnd,
                  progress.capturedSampleEnd >= lane.progress.capturedSampleEnd,
                  progress.consumedSampleEnd >= 0, progress.consumedSampleEnd <= progress.effectiveASRConsumedSampleEnd,
                  progress.effectiveASRConsumedSampleEnd <= progress.admittedSampleEnd,
                  progress.admittedSampleEnd <= progress.capturedSampleEnd,
                  lane.epoch.meetingOriginNanoseconds == nil || meetingTime(progress.capturedSampleEnd, in: lane.epoch) != nil else {
                return .rejected(.invalidRange)
            }
            changed = progress != lane.progress
            lane.progress = progress
        case .partial(let partial):
            guard lane.availability == .active || lane.availability == .paused else { return .rejected(.invalidRange) }
            guard partial.samples.isValid,
                  partial.samples.start >= lane.settled, partial.samples.end <= lane.progress.admittedSampleEnd,
                  partial.text.utf8.count <= 65536 else { return .rejected(.invalidRange) }
            if let prior = lane.partial {
                if prior == partial { result = .duplicate }
                else if partial.revision <= prior.revision { return .rejected(.outOfOrder) }
            }
            lane.partial = partial
        case .committed(let segment):
            guard lane.availability == .active || lane.availability == .paused else { return .rejected(.invalidRange) }
            if let prior = segments[segment.id] {
                guard prior == segment else { return .rejected(.conflictingID) }
                result = .duplicate
            } else {
                guard segment.isValid, validSettlement(segment.range, in: lane, consumed: true),
                      validDiarizerScope(segment) else {
                    return .rejected(.invalidRange)
                }
                inserted = segment
                settled = .init(epochID: event.epochID, source: event.source, range: segment.range, kind: .committed,
                                committedSegmentID: segment.id)
            }
        case .settled(let interval):
            guard interval.kind != .committed, interval.committedSegmentID == nil,
                  validSettlement(interval.range, in: lane, consumed: interval.kind == .processedSilence) else {
                return .rejected(.invalidRange)
            }
            if interval.kind == .processedSilence, lane.availability != .active && lane.availability != .paused { return .rejected(.invalidRange) }
            settled = interval
        case .availability(let availability):
            if availability == .disabled || availability == .unavailable {
                guard lane.settled == lane.progress.capturedSampleEnd else { return .rejected(.unsettledEpoch) }
            }
            if availability == .active || availability == .paused,
               lane.availability == .disabled || lane.availability == .unavailable,
               let prior = lane.meeting, let cutoff = lastKnownCutoff, prior < cutoff { return .rejected(.invalidRange) }
            changed = availability != lane.availability
            lane.availability = availability
        }
        if let inserted { segments[inserted.id] = inserted }
        if let settled {
            coverage.append(settled)
            for slice in settled.range.savedAudio { savedFrontiers[slice.destination] = slice }
            // Settlement validation above requires normalized samples.
            lane.settled = settled.range.samples?.end ?? lane.settled
            lane.meeting = settled.range.meeting?.endNanoseconds
            if let meeting = lane.meeting { qualifiedFrontiers[event.source] = meeting }
            lane.partial = nil
            changed = true
        }
        lane.nextSequence += 1
        lane.lastEvent = event
        lanes[event.source] = lane
        if changed { revision += 1 }
        refreshCutoff()
        return result
    }

    private func meetingTime(_ sample: Int64, in epoch: LiveEpoch) -> Int64? {
        guard sample >= 0, let origin = epoch.meetingOriginNanoseconds else { return nil }
        let offset = sample.multipliedReportingOverflow(by: 62500) // normalized 16 kHz
        guard !offset.overflow else { return nil }
        let result = origin.addingReportingOverflow(offset.partialValue)
        return result.overflow ? nil : result.partialValue
    }

    private func validSettlement(_ range: LiveEvidenceRange, in lane: Lane, consumed: Bool) -> Bool {
        guard range.isValid, let samples = range.samples, samples.start == lane.settled,
              samples.end <= (consumed ? lane.progress.effectiveASRConsumedSampleEnd : lane.progress.capturedSampleEnd) else { return false }
        if lane.epoch.meetingOriginNanoseconds != nil {
            guard let meeting = range.meeting, meeting.startNanoseconds == lane.meeting,
                  meeting.startNanoseconds == meetingTime(samples.start, in: lane.epoch),
                  meeting.endNanoseconds == meetingTime(samples.end, in: lane.epoch) else { return false }
        } else if range.meeting != nil { return false }
        for slice in range.savedAudio {
            guard slice.samples != nil, slice.destination == .track(lane.epoch.source) else { return false }
            if let prior = savedFrontiers[slice.destination],
               prior.sampleRate != slice.sampleRate || slice.startFrame < prior.startFrame + prior.frameCount { return false }
        }
        return true
    }

    private func registerDiarizerWhileValid(owner: LiveSessionIdentity, source: LiveSource, contextID: UUID) -> LiveStoreAdmission {
        guard owner == identity else { return .rejected(.wrongOwner) }
        guard !isClosed else { return .rejected(.closed) }
        guard source.isCaptureSource, let lane = lanes[source] else { return .rejected(.invalidAnnotation) }
        if diarizers[source]?.id == contextID { return .duplicate }
        guard knownDiarizers[source]?.contains(contextID) != true else { return .rejected(.invalidAnnotation) }
        knownDiarizers[source, default: []].insert(contextID)
        diarizers[source] = Diarizer(id: contextID, meetingStart: meetingTime(lane.progress.capturedSampleEnd, in: lane.epoch),
            firstEpochOrder: epochOrder[lane.epoch.id]!, firstSample: lane.progress.capturedSampleEnd)
        return .accepted
    }

    private func validDiarizerScope(_ segment: CommittedLiveSegment) -> Bool {
        guard let context = segment.diarizerContextID else { return true }
        guard let diarizer = diarizers[segment.source], diarizer.id == context,
              let order = epochOrder[segment.id.epochID], let samples = segment.range.samples,
              order >= diarizer.firstEpochOrder else { return false }
        return order > diarizer.firstEpochOrder || samples.start >= diarizer.firstSample
    }

    private func qualifiedDiarizerStart(_ diarizer: Diarizer, source: LiveSource) -> Int64? {
        if let start = diarizer.meetingStart { return start }
        // A later qualified ASR anchor recovers chronology without resetting
        // the independent speaker namespace or inventing earlier meeting time.
        return epochs.values.filter {
            $0.source == source && (epochOrder[$0.id] ?? -1) > diarizer.firstEpochOrder
        }.compactMap(\.meetingOriginNanoseconds).min()
    }

    private func annotateWhileValid(owner: LiveSessionIdentity, source: LiveSource, contextID: UUID, sequence: UInt64,
                  annotations updates: [LiveSpeakerAnnotation], coverage newCoverage: [LiveAttributionCoverage] = []) -> LiveStoreAdmission {
        guard owner == identity else { return .rejected(.wrongOwner) }
        guard !isClosed else { return .rejected(.closed) }
        guard var diarizer = diarizers[source], diarizer.id == contextID else { return .rejected(.invalidAnnotation) }
        let batch = AnnotationBatch(sequence: sequence, annotations: updates, coverage: newCoverage)
        if batch == diarizer.lastBatch { return .duplicate }
        guard sequence == diarizer.nextSequence, sequence < .max else { return .rejected(.outOfOrder) }
        guard revision < .max, annotationRevision < .max, updates.count <= 4096, newCoverage.count <= 2048 else { return .rejected(.invalidAnnotation) }
        var keys = Set<AnnotationKey>()
        for annotation in updates {
            guard let segment = segments[annotation.segmentID], segment.source == source,
                  segment.diarizerContextID == contextID, validDiarizerScope(segment), validAnnotation(annotation, segment: segment),
                  keys.insert(.init(segment: annotation.segmentID, word: annotation.wordIndex)).inserted else { return .rejected(.invalidAnnotation) }
        }
        let settledTime = coverage.filter { $0.source == source }.compactMap { $0.range.meeting?.endNanoseconds }.max()
        for interval in newCoverage {
            guard interval.source == source, interval.contextID == contextID else { return .rejected(.invalidAnnotation) }
            if let meeting = interval.meeting {
                guard let start = qualifiedDiarizerStart(diarizer, source: source), meeting.isValid, meeting.startNanoseconds >= start,
                      meeting.endNanoseconds <= (settledTime ?? -1),
                      !segments.values.contains(where: { segment in
                          guard segment.source == source, segment.diarizerContextID != contextID,
                                let other = segment.range.meeting else { return false }
                          return other.startNanoseconds < meeting.endNanoseconds && meeting.startNanoseconds < other.endNanoseconds
                      }) else { return .rejected(.invalidAnnotation) }
            } else if interval.status == .resolved || interval.status == .overlap { return .rejected(.invalidAnnotation) }
        }
        for annotation in updates { annotations[.init(segment: annotation.segmentID, word: annotation.wordIndex)] = annotation }
        for interval in newCoverage { replaceAttributionCoverage(interval) }
        diarizer.nextSequence += 1; diarizer.lastBatch = batch; diarizers[source] = diarizer
        revision += 1; annotationRevision += 1
        return .accepted
    }

    private func replaceAttributionCoverage(_ update: LiveAttributionCoverage) {
        attributionCoverage = attributionCoverage.flatMap { prior -> [LiveAttributionCoverage] in
            guard prior.source == update.source, prior.contextID == update.contextID else { return [prior] }
            guard let new = update.meeting else { return prior.meeting == nil ? [] : [prior] }
            guard let old = prior.meeting, old.startNanoseconds < new.endNanoseconds,
                  new.startNanoseconds < old.endNanoseconds else { return [prior] }
            var retained: [LiveAttributionCoverage] = []
            if old.startNanoseconds < new.startNanoseconds {
                retained.append(.init(source: prior.source, contextID: prior.contextID,
                    meeting: .init(startNanoseconds: old.startNanoseconds, endNanoseconds: new.startNanoseconds), status: prior.status))
            }
            if new.endNanoseconds < old.endNanoseconds {
                retained.append(.init(source: prior.source, contextID: prior.contextID,
                    meeting: .init(startNanoseconds: new.endNanoseconds, endNanoseconds: old.endNanoseconds), status: prior.status))
            }
            return retained
        }
        attributionCoverage.append(update)
        attributionCoverage.sort {
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            if $0.contextID != $1.contextID { return $0.contextID.uuidString < $1.contextID.uuidString }
            return ($0.meeting?.startNanoseconds ?? .max) < ($1.meeting?.startNanoseconds ?? .max)
        }
    }

    private func validAnnotation(_ annotation: LiveSpeakerAnnotation, segment: CommittedLiveSegment) -> Bool {
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

    private func closeWhileValid(owner: LiveSessionIdentity) -> LiveStoreAdmission {
        guard owner == identity else { return .rejected(.wrongOwner) }
        if isClosed { return .duplicate }
        guard lanes.values.allSatisfy({ $0.settled == $0.progress.capturedSampleEnd }) else { return .rejected(.unsettledEpoch) }
        guard revision < .max else { return .rejected(.invalidRange) }
        isClosed = true
        for source in lanes.keys { lanes[source]?.partial = nil }
        revision += 1
        return .accepted
    }

    /// This is source publication, not persistence. The recording/pipeline owner
    /// supplies only a complete source after its durable transcription seam.
    private func publishFinalWhileValid(_ publication: TranscriptSourcePublication) -> LiveStoreAdmission {
        guard publication.identity == identity else { return .rejected(.wrongOwner) }
        guard isClosed else { return .rejected(.unsettledEpoch) }
        if publication == finalPublication { return .duplicate }
        guard !retiredPublications.contains(publication.id) else { return .rejected(.conflictingID) }
        guard publication.revision > (finalPublication?.revision ?? 0), revision < .max, annotationRevision < .max,
              publication.segments.count <= 100000, publication.annotations.count <= 100000 else { return .rejected(.stalePublication) }
        if let prior = finalPublication, prior.id == publication.id, prior.segments != publication.segments { return .rejected(.conflictingID) }
        var byID: [LiveSegmentID: CommittedLiveSegment] = [:]
        for segment in publication.segments {
            guard segment.source == .finalMix, segment.id.epochID == publication.id, segment.isValid,
                  segment.range.samples == nil, segment.range.meeting == nil,
                  segment.range.savedAudio.allSatisfy({ $0.samples == nil && $0.destination == .master }),
                  byID.updateValue(segment, forKey: segment.id) == nil else { return .rejected(.invalidRange) }
        }
        var keys = Set<AnnotationKey>()
        for annotation in publication.annotations {
            guard let segment = byID[annotation.segmentID], validAnnotation(annotation, segment: segment),
                  keys.insert(.init(segment: annotation.segmentID, word: annotation.wordIndex)).inserted else { return .rejected(.invalidAnnotation) }
        }
        if let prior = finalPublication, prior.id != publication.id { retiredPublications.insert(prior.id) }
        finalPublication = publication
        revision += 1; annotationRevision += 1
        return .accepted
    }

    private func refreshCutoff() {
        let participating = lanes.values.filter { ($0.availability == .active || $0.availability == .paused) && $0.epoch.meetingOriginNanoseconds != nil }
        if let cutoff = participating.compactMap(\.meeting).min() { lastKnownCutoff = cutoff }
    }

    private func laneValues() -> [LiveLaneWatermarks] {
        lanes.values.map { .init(epoch: $0.epoch, availability: $0.availability, progress: $0.progress,
            settledSampleEnd: $0.settled, settledMeetingNanoseconds: $0.meeting) }.sorted { $0.epoch.source.rawValue < $1.epoch.source.rawValue }
    }

    private func ordered(_ values: [CommittedLiveSegment]) -> [CommittedLiveSegment] {
        values.sorted {
            let a = $0.range.meeting?.startNanoseconds ?? .max, b = $1.range.meeting?.startNanoseconds ?? .max
            if a != b { return a < b }
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            if $0.id.epochID != $1.id.epochID { return $0.id.epochID.uuidString < $1.id.epochID.uuidString }
            return $0.id.index < $1.id.index
        }
    }

    func projection() -> LiveTranscriptProjection {
        .init(segments: ordered(Array(segments.values)), partials: lanes.values.compactMap(\.partial).sorted { $0.source.rawValue < $1.source.rawValue },
              lanes: laneValues(), revision: revision, isClosed: isClosed, coverage: coverage, captureLosses: captureLosses)
    }

    /// Preview retirement changes display only; frozen evidence is unaffected.
    private func clearPartialsWhileValid(owner: LiveSessionIdentity, source: LiveSource?) -> LiveStoreAdmission {
        guard owner == identity else { return .rejected(.wrongOwner) }
        guard !isClosed else { return .duplicate }
        for candidate in lanes.keys where source == nil || source == candidate { lanes[candidate]?.partial = nil }
        return .accepted
    }

    func snapshot(selection: LiveSnapshotSelection = .committed) -> TranscriptSnapshot {
        let publication = finalPublication, isFinal = publication != nil
        let cutoff = isFinal ? nil : lastKnownCutoff
        let all = ordered(publication?.segments ?? Array(segments.values))
        var scope: TranscriptSnapshot.Scope = isFinal ? .completeFinal : .liveThroughCutoff
        var lower: Int64 = 0, upper = cutoff ?? .max
        var requestedIDs: Set<LiveSegmentID>?, includeUnaligned = false
        switch selection {
        case .committed: break
        case .range(let range):
            scope = .selectedRange
            lower = range.startNanoseconds; upper = range.isValid ? min(upper, range.endNanoseconds) : -1
        case .evidence(let ids, let unaligned):
            scope = .selectedEvidence; requestedIDs = Set(ids); includeUnaligned = unaligned
        }
        let included = all.filter { segment in
            if let requestedIDs, !requestedIDs.contains(segment.id) { return false }
            if let meeting = segment.range.meeting {
                return (isFinal || cutoff != nil) && meeting.startNanoseconds >= lower && meeting.endNanoseconds <= upper
            }
            if case .range = selection { return false }
            return isFinal || (requestedIDs != nil && includeUnaligned)
        }
        if !isFinal && included.contains(where: { $0.range.meeting == nil }) { scope = .unalignedEvidence }
        let ids = Set(included.map(\.id))
        var selectedCoverage: [LiveCoverageSelection] = []
        if !isFinal {
            for interval in coverage {
                let textIncluded = interval.committedSegmentID.map { ids.contains($0) } ?? false
                if let meeting = interval.range.meeting, cutoff != nil {
                    let start = max(lower, meeting.startNanoseconds), end = min(upper, meeting.endNanoseconds)
                    if end > start { selectedCoverage.append(.init(interval: interval,
                        includedMeeting: .init(startNanoseconds: start, endNanoseconds: end), textIncluded: textIncluded)) }
                } else if includeUnaligned && textIncluded { selectedCoverage.append(.init(interval: interval, includedMeeting: nil, textIncluded: true)) }
            }
            // Disabled/missing/unaligned sources do not pin other lanes' cutoff;
            // retain their missing chronology rather than treating it as silence.
            if cutoff != nil {
                for source in LiveSource.allCases where source.isCaptureSource {
                    let lane = lanes[source]
                    let reason: LiveGapReason
                    let start: Int64
                    if lane == nil { reason = .unavailable; start = 0 }
                    else if lane?.epoch.meetingOriginNanoseconds == nil {
                        reason = .unknownClock
                        start = coverage.filter { $0.source == source }.compactMap { $0.range.meeting?.endNanoseconds }.max() ?? 0
                    } else if lane?.availability == .disabled || lane?.availability == .unavailable {
                        reason = lane?.availability == .disabled ? .disabled : .unavailable
                        start = lane?.meeting ?? 0
                    } else { continue }
                    let includedStart = max(lower, start)
                    if upper > includedStart {
                        let range = LiveMeetingRange(startNanoseconds: includedStart, endNanoseconds: upper)
                        selectedCoverage.append(.init(interval: .init(epochID: nil, source: source,
                            range: .init(samples: nil, meeting: range), kind: .gap(reason)), includedMeeting: range))
                    }
                }
            }
        }
        let frozenAnnotations = (publication?.annotations ?? Array(annotations.values)).filter { ids.contains($0.segmentID) }.sorted {
            if $0.segmentID.epochID != $1.segmentID.epochID { return $0.segmentID.epochID.uuidString < $1.segmentID.epochID.uuidString }
            if $0.segmentID.index != $1.segmentID.index { return $0.segmentID.index < $1.segmentID.index }
            return ($0.wordIndex ?? -1) < ($1.wordIndex ?? -1)
        }
        var legend = Set<SpeakerTrackKey>()
        for annotation in frozenAnnotations {
            switch annotation.assignment {
            case .track(let key): legend.insert(key)
            case .overlap(let tracks): legend.formUnion(tracks)
            case .unknown: break
            }
        }
        let frozenAttribution = isFinal ? [] : attributionCoverage.compactMap { interval -> LiveAttributionCoverage? in
            guard let meeting = interval.meeting, cutoff != nil else { return nil }
            let start = max(lower, meeting.startNanoseconds), end = min(upper, meeting.endNanoseconds)
            return end > start ? .init(source: interval.source, contextID: interval.contextID,
                meeting: .init(startNanoseconds: start, endNanoseconds: end), status: interval.status) : nil
        }
        let excluded = isFinal ? [] : LiveSource.allCases.filter { source in
            guard source.isCaptureSource else { return false }
            guard let lane = lanes[source] else { return true }
            return lane.epoch.meetingOriginNanoseconds == nil || lane.availability == .disabled || lane.availability == .unavailable
        }
        return .init(identity: identity, sourceVersion: isFinal ? .final : .live,
            sourcePublicationID: publication?.id ?? identity.captureSessionID, sourcePublicationRevision: publication?.revision ?? 0,
            revision: revision, annotationRevision: annotationRevision, cutoffNanoseconds: scope == .unalignedEvidence ? nil : cutoff,
            scope: scope, segments: included, lanes: isFinal ? [] : laneValues(), excludedSources: excluded, coverage: selectedCoverage,
            annotations: frozenAnnotations, attributionCoverage: frozenAttribution, speakerLegend: legend.sorted {
                if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
                if $0.contextID != $1.contextID { return $0.contextID.uuidString < $1.contextID.uuidString }
                return $0.slot < $1.slot
            }, captureLosses: isFinal || captureLosses.isEmpty ? nil : captureLosses)
    }
}
