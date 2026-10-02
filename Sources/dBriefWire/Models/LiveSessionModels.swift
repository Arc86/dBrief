import Foundation

public struct LiveSessionIdentity: Codable, Sendable, Hashable {
    public let recordingID: UUID
    public let captureSessionID: UUID
    public init(recordingID: UUID, captureSessionID: UUID) {
        self.recordingID = recordingID; self.captureSessionID = captureSessionID
    }
}

public enum LiveSource: String, Codable, Sendable, CaseIterable {
    case microphone, system, finalMix
    public var isCaptureSource: Bool { self != .finalMix }
}

public struct LiveSegmentID: Codable, Sendable, Hashable, CustomStringConvertible {
    public let epochID: UUID
    public let index: UInt64
    public init(epochID: UUID, index: UInt64) { self.epochID = epochID; self.index = index }
    public var description: String { "\(epochID.uuidString.lowercased()):\(index)" }
}

public struct LiveSampleRange: Codable, Sendable, Equatable {
    public let start: Int64
    public let end: Int64
    public init(start: Int64, end: Int64) { self.start = start; self.end = end }
    public var isValid: Bool { start >= 0 && end > start }
    public func contains(_ other: Self) -> Bool { isValid && other.isValid && other.start >= start && other.end <= end }
}

public struct LiveMeetingRange: Codable, Sendable, Equatable {
    public let startNanoseconds: Int64
    public let endNanoseconds: Int64
    public init(startNanoseconds: Int64, endNanoseconds: Int64) {
        self.startNanoseconds = startNanoseconds; self.endNanoseconds = endNanoseconds
    }
    public var isValid: Bool { startNanoseconds >= 0 && endNanoseconds > startNanoseconds }
}

public struct LiveSavedAudioSlice: Codable, Sendable, Equatable {
    public enum Destination: Codable, Sendable, Hashable { case track(LiveSource), master }
    public let samples: LiveSampleRange?
    public let destination: Destination
    public let startFrame: Int64
    public let frameCount: Int64
    public let sampleRate: Int64
    public let mappingRevision: UInt64
    public init(samples: LiveSampleRange?, destination: Destination, startFrame: Int64, frameCount: Int64,
                sampleRate: Int64, mappingRevision: UInt64) {
        self.samples = samples; self.destination = destination; self.startFrame = startFrame
        self.frameCount = frameCount; self.sampleRate = sampleRate; self.mappingRevision = mappingRevision
    }
    public var isValid: Bool {
        startFrame >= 0 && frameCount > 0 && !startFrame.addingReportingOverflow(frameCount).overflow &&
            sampleRate > 0 && sampleRate <= 384000 && (samples?.isValid ?? true)
    }
}

public struct LiveEvidenceRange: Codable, Sendable, Equatable {
    public let samples: LiveSampleRange?
    public let meeting: LiveMeetingRange?
    public let savedAudio: [LiveSavedAudioSlice]
    public init(samples: LiveSampleRange?, meeting: LiveMeetingRange?, savedAudio: [LiveSavedAudioSlice] = []) {
        self.samples = samples; self.meeting = meeting; self.savedAudio = savedAudio
    }
    public var isValid: Bool {
        guard samples?.isValid ?? true, meeting?.isValid ?? true, savedAudio.count <= 512 else { return false }
        var previousEnd: Int64?
        var savedFrontiers: [LiveSavedAudioSlice.Destination: LiveSavedAudioSlice] = [:]
        for slice in savedAudio {
            guard slice.isValid else { return false }
            if let range = slice.samples {
                guard let samples, samples.contains(range) else { return false }
                if let previousEnd, range.start < previousEnd { return false }
                previousEnd = range.end
            }
            // A mapping revision does not create a different audio file.
            if let prior = savedFrontiers[slice.destination],
               prior.sampleRate != slice.sampleRate || slice.startFrame < prior.startFrame + prior.frameCount { return false }
            savedFrontiers[slice.destination] = slice
        }
        return true
    }
}

public enum LiveSourceAvailability: String, Codable, Sendable { case active, paused, disabled, unavailable }

public struct LiveEpoch: Codable, Sendable, Equatable {
    public let id: UUID
    public let source: LiveSource
    public let engineRevision: String
    public let language: String
    public let meetingOriginNanoseconds: Int64?
    public let availability: LiveSourceAvailability
    public init(id: UUID, source: LiveSource, engineRevision: String, language: String,
                meetingOriginNanoseconds: Int64?, availability: LiveSourceAvailability = .active) {
        self.id = id; self.source = source; self.engineRevision = engineRevision; self.language = language
        self.meetingOriginNanoseconds = meetingOriginNanoseconds; self.availability = availability
    }
}

public struct LiveWordSpan: Codable, Sendable, Equatable {
    public let text: String
    /// Decoder estimates; these do not prove acoustic word alignment.
    public let samples: LiveSampleRange?
    /// May be synthetic. Attribution cannot treat this as calibrated probability.
    public let confidence: Double?
    public init(text: String, samples: LiveSampleRange?, confidence: Double? = nil) {
        self.text = text; self.samples = samples; self.confidence = confidence
    }
}

public struct CommittedLiveSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: LiveSegmentID
    public let source: LiveSource
    public let range: LiveEvidenceRange
    public let text: String
    public let words: [LiveWordSpan]
    public let language: String?
    public let diarizerContextID: UUID?
    public init(id: LiveSegmentID, source: LiveSource, range: LiveEvidenceRange, text: String,
                words: [LiveWordSpan] = [], language: String? = nil, diarizerContextID: UUID? = nil) {
        self.id = id; self.source = source; self.range = range; self.text = text; self.words = words
        self.language = language; self.diarizerContextID = diarizerContextID
    }
    public var isValid: Bool {
        guard range.isValid, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 65536, words.count <= 4096 else { return false }
        for word in words {
            guard !word.text.isEmpty, word.text.utf8.count <= 4096,
                  word.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { return false }
            if let wordSamples = word.samples {
                guard let samples = range.samples, samples.contains(wordSamples) else { return false }
            }
        }
        return true
    }
}

public struct LivePartial: Codable, Sendable, Equatable {
    public let epochID: UUID
    public let source: LiveSource
    public let revision: UInt64
    public let samples: LiveSampleRange
    public let text: String
    public init(epochID: UUID, source: LiveSource, revision: UInt64, samples: LiveSampleRange, text: String) {
        self.epochID = epochID; self.source = source; self.revision = revision; self.samples = samples; self.text = text
    }
}

public struct LiveLaneProgress: Codable, Sendable, Equatable {
    public let capturedSampleEnd: Int64
    public let admittedSampleEnd: Int64
    public let consumedSampleEnd: Int64
    public init(capturedSampleEnd: Int64, admittedSampleEnd: Int64, consumedSampleEnd: Int64) {
        self.capturedSampleEnd = capturedSampleEnd; self.admittedSampleEnd = admittedSampleEnd
        self.consumedSampleEnd = consumedSampleEnd
    }
}

public enum LiveGapReason: String, Codable, Sendable {
    case preparation, disabled, unavailable, overload, engineRestart, deviceInterruption, stopped, deadline, unknownClock
}

public struct LiveRawFrameRange: Codable, Sendable, Equatable {
    public let startFrame: Int64
    public let frameCount: Int64
    public let sampleRate: Double
    public init(startFrame: Int64, frameCount: Int64, sampleRate: Double) {
        self.startFrame = startFrame; self.frameCount = frameCount; self.sampleRate = sampleRate
    }
    public var isValid: Bool {
        startFrame >= 0 && frameCount > 0 && !startFrame.addingReportingOverflow(frameCount).overflow &&
            sampleRate.isFinite && sampleRate >= 1 && sampleRate <= 384000 && sampleRate.rounded(.down) == sampleRate
    }
}

/// Raw-source uncertainty has no established normalized, meeting or saved-audio
/// coordinates. Even a selected snapshot cannot place it inside a time window.
public struct LiveCaptureRawLoss: Codable, Sendable, Equatable {
    public let id: UUID
    public let source: LiveSource
    public let sourceEpoch: UUID?
    public let frames: LiveRawFrameRange?
    public let reason: LiveGapReason
    public let bufferCount: Int64
    public init(id: UUID, source: LiveSource, sourceEpoch: UUID?, frames: LiveRawFrameRange?, reason: LiveGapReason, bufferCount: Int64) {
        self.id = id; self.source = source; self.sourceEpoch = sourceEpoch; self.frames = frames
        self.reason = reason; self.bufferCount = bufferCount
    }
    public var isValid: Bool { source.isCaptureSource && bufferCount > 0 && (frames?.isValid ?? true) && (frames == nil || sourceEpoch != nil) }
}

public struct LiveCoverageInterval: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable { case committed, processedSilence, gap(LiveGapReason) }
    /// Nil for a declared source absence with no admitted normalized samples.
    public let epochID: UUID?
    public let source: LiveSource
    public let range: LiveEvidenceRange
    public let kind: Kind
    public let committedSegmentID: LiveSegmentID?
    public init(epochID: UUID?, source: LiveSource, range: LiveEvidenceRange, kind: Kind, committedSegmentID: LiveSegmentID? = nil) {
        self.epochID = epochID; self.source = source; self.range = range; self.kind = kind
        self.committedSegmentID = committedSegmentID
    }
}

public struct LiveTranscriptEvent: Codable, Sendable, Equatable {
    public enum Payload: Codable, Sendable, Equatable {
        case progress(LiveLaneProgress), partial(LivePartial), committed(CommittedLiveSegment)
        case settled(LiveCoverageInterval), availability(LiveSourceAvailability)
    }
    public let identity: LiveSessionIdentity
    public let epochID: UUID
    public let source: LiveSource
    public let sequence: UInt64
    public let payload: Payload
    public init(identity: LiveSessionIdentity, epochID: UUID, source: LiveSource, sequence: UInt64, payload: Payload) {
        self.identity = identity; self.epochID = epochID; self.source = source; self.sequence = sequence; self.payload = payload
    }
}

public struct SpeakerTrackKey: Codable, Sendable, Hashable {
    public let captureSessionID: UUID
    public let source: LiveSource
    public let contextID: UUID
    public let slot: Int
    public init(captureSessionID: UUID, source: LiveSource, contextID: UUID, slot: Int) {
        self.captureSessionID = captureSessionID; self.source = source; self.contextID = contextID; self.slot = slot
    }
}

public struct LiveSpeakerAnnotation: Codable, Sendable, Equatable {
    public enum Assignment: Codable, Sendable, Equatable { case track(SpeakerTrackKey), unknown, overlap([SpeakerTrackKey]) }
    public let segmentID: LiveSegmentID
    public let wordIndex: Int?
    public let assignment: Assignment
    public init(segmentID: LiveSegmentID, wordIndex: Int? = nil, assignment: Assignment) {
        self.segmentID = segmentID; self.wordIndex = wordIndex; self.assignment = assignment
    }
}

public struct LiveAttributionCoverage: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case resolved, unknown, overlap, unavailable }
    public let source: LiveSource
    public let contextID: UUID
    public let meeting: LiveMeetingRange?
    public let status: Status
    public init(source: LiveSource, contextID: UUID, meeting: LiveMeetingRange?, status: Status) {
        self.source = source; self.contextID = contextID; self.meeting = meeting; self.status = status
    }
}

public struct LiveLaneWatermarks: Codable, Sendable, Equatable {
    public let epoch: LiveEpoch
    public let availability: LiveSourceAvailability
    public let progress: LiveLaneProgress
    public let settledSampleEnd: Int64
    public let settledMeetingNanoseconds: Int64?
    public init(epoch: LiveEpoch, availability: LiveSourceAvailability, progress: LiveLaneProgress,
                settledSampleEnd: Int64, settledMeetingNanoseconds: Int64?) {
        self.epoch = epoch; self.availability = availability; self.progress = progress
        self.settledSampleEnd = settledSampleEnd; self.settledMeetingNanoseconds = settledMeetingNanoseconds
    }
}

public struct LiveCoverageSelection: Codable, Sendable, Equatable {
    public let interval: LiveCoverageInterval
    public let includedMeeting: LiveMeetingRange?
    /// A decoded utterance crossing the cutoff is omitted as a whole from text.
    public let textIncluded: Bool
    public init(interval: LiveCoverageInterval, includedMeeting: LiveMeetingRange?, textIncluded: Bool = false) {
        self.interval = interval; self.includedMeeting = includedMeeting; self.textIncluded = textIncluded
    }
}

public struct TranscriptSourcePublication: Codable, Sendable, Equatable {
    public let identity: LiveSessionIdentity
    public let id: UUID
    public let revision: UInt64
    public let segments: [CommittedLiveSegment]
    public let annotations: [LiveSpeakerAnnotation]
    public init(identity: LiveSessionIdentity, id: UUID, revision: UInt64, segments: [CommittedLiveSegment],
                annotations: [LiveSpeakerAnnotation] = []) {
        self.identity = identity; self.id = id; self.revision = revision
        self.segments = segments; self.annotations = annotations
    }
}

public struct TranscriptSnapshot: Codable, Sendable, Equatable {
    public enum SourceVersion: String, Codable, Sendable { case live, final }
    public enum Scope: String, Codable, Sendable { case liveThroughCutoff, selectedRange, selectedEvidence, unalignedEvidence, completeFinal }
    public let identity: LiveSessionIdentity
    public let sourceVersion: SourceVersion
    public let sourcePublicationID: UUID
    public let sourcePublicationRevision: UInt64
    public let revision: UInt64
    public let annotationRevision: UInt64
    public let cutoffNanoseconds: Int64?
    public let scope: Scope
    public let segments: [CommittedLiveSegment]
    public let lanes: [LiveLaneWatermarks]
    public let excludedSources: [LiveSource]
    public let coverage: [LiveCoverageSelection]
    public let annotations: [LiveSpeakerAnnotation]
    public let attributionCoverage: [LiveAttributionCoverage]
    public let speakerLegend: [SpeakerTrackKey]
    /// Absent in older snapshots and final-source publications.
    public let captureLosses: [LiveCaptureRawLoss]?
    public init(identity: LiveSessionIdentity, sourceVersion: SourceVersion, sourcePublicationID: UUID,
                sourcePublicationRevision: UInt64, revision: UInt64, annotationRevision: UInt64,
                cutoffNanoseconds: Int64?, scope: Scope, segments: [CommittedLiveSegment], lanes: [LiveLaneWatermarks],
                excludedSources: [LiveSource], coverage: [LiveCoverageSelection], annotations: [LiveSpeakerAnnotation],
                attributionCoverage: [LiveAttributionCoverage], speakerLegend: [SpeakerTrackKey], captureLosses: [LiveCaptureRawLoss]? = nil) {
        self.identity = identity; self.sourceVersion = sourceVersion; self.sourcePublicationID = sourcePublicationID
        self.sourcePublicationRevision = sourcePublicationRevision; self.revision = revision
        self.annotationRevision = annotationRevision; self.cutoffNanoseconds = cutoffNanoseconds; self.scope = scope
        self.segments = segments; self.lanes = lanes; self.excludedSources = excludedSources; self.coverage = coverage
        self.annotations = annotations; self.attributionCoverage = attributionCoverage; self.speakerLegend = speakerLegend
        self.captureLosses = captureLosses
    }
}
