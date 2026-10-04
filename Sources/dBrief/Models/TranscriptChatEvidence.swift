import Foundation
import dBriefWire

/// Codable values deliberately contain no Endpoint or credentials.
struct ChatRouteBasis: Codable, Sendable, Equatable {
    let engine: String
    let endpointID: UUID?
    let provider: String?
    let origin: String?
    let model: String?
}

struct ChatContextBudget: Codable, Sendable, Equatable {
    let contextTokens: Int
    let outputTokens: Int
    let templateReserve: Int
    var inputAllowance: Int { max(0, contextTokens - outputTokens - templateReserve) }
}

struct ChatBudgetReceipt: Codable, Sendable, Equatable {
    let contextTokens: Int
    let estimatedPromptTokens: Int
    let outputTokens: Int
    let templateReserve: Int
    let counting: String
    var totalReserved: Int { estimatedPromptTokens + outputTokens + templateReserve }
}

struct ChatTranscriptSource: Codable, Sendable, Equatable {
    enum Version: String, Codable, Sendable { case live, final, legacy }
    let recordingID: UUID?
    let captureSessionID: UUID?
    let version: Version
    let publicationID: UUID?
    let publicationRevision: UInt64?
    let textRevision: UInt64?
    let annotationRevision: UInt64?
    let cutoffNanoseconds: Int64?
    let scope: TranscriptSnapshot.Scope?
    let speakerLegend: [SpeakerLabel]
    /// Source facts, with text removed. References always use sent evidence.
    let liveMetadata: TranscriptSnapshot?

    static func legacy(recordingID: UUID?, live: Bool = false, speakerLabels: [SpeakerLabel] = []) -> Self {
        .init(recordingID: recordingID, captureSessionID: nil, version: live ? .live : .legacy,
              publicationID: nil, publicationRevision: nil, textRevision: nil, annotationRevision: nil,
              cutoffNanoseconds: nil, scope: nil, speakerLegend: speakerLabels, liveMetadata: nil)
    }

    var label: String {
        switch version {
        case .live:
            if let cutoffNanoseconds { return "Live transcript through \(Self.time(cutoffNanoseconds))" }
            return "Live transcript — timing unqualified"
        case .final: return "Final transcript"
        case .legacy: return "Transcript — provenance unavailable"
        }
    }

    static func time(_ nanoseconds: Int64) -> String {
        let seconds = max(0, nanoseconds / 1_000_000_000)
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }

    var coverageDescription: String {
        guard let metadata = liveMetadata else {
            return version == .final ? "Durable completed transcript." : "Source coverage and audio timing are unqualified."
        }
        let gaps = metadata.coverage.filter { if case .gap = $0.interval.kind { return true }; return false }
        let excluded = metadata.excludedSources.map(\.rawValue).joined(separator: ", ")
        let detail = gaps.prefix(8).map { gap in
            let reason: String
            if case .gap(let value) = gap.interval.kind { reason = value.rawValue } else { reason = "" }
            let range = gap.includedMeeting.map { "\(Self.time($0.startNanoseconds))–\(Self.time($0.endNanoseconds))" } ?? "unaligned"
            return "\(gap.interval.source.rawValue) \(range): \(reason)"
        }.joined(separator: "; ")
        return "\(gaps.count) coverage gaps; \(metadata.captureLosses?.count ?? 0) capture-loss receipts."
            + (excluded.isEmpty ? "" : " Excluded sources: \(excluded).")
            + (detail.isEmpty ? "" : " \(detail).")
            + (gaps.count > 8 ? " Further gaps are retained in this answer's source metadata." : "")
            + (metadata.attributionCoverage.isEmpty ? " Speaker attribution is unqualified." : " Speaker attribution coverage is retained separately.")
    }
}

/// Optional word-level facts frozen with the exact supplied evidence.
struct ChatSpeakerAttributionSpan: Codable, Sendable, Equatable {
    let startUTF8: Int
    let endUTF8: Int
    let status: LiveAttributionCoverage.Status
    let speakers: [String]
}

struct ChatTranscriptSegment: Sendable, Equatable {
    let id: String
    let source: String
    let text: String
    let meeting: LiveMeetingRange?
    let savedAudio: [LiveSavedAudioSlice]
    let finalPlayback: ChatFinalPlaybackRange?
    let speakers: [String]
    let speakerAttribution: [ChatSpeakerAttributionSpan]?
    init(id: String, source: String, text: String, meeting: LiveMeetingRange? = nil,
         savedAudio: [LiveSavedAudioSlice] = [], finalPlayback: ChatFinalPlaybackRange? = nil, speakers: [String] = [],
         speakerAttribution: [ChatSpeakerAttributionSpan]? = nil) {
        self.id = id; self.source = source; self.text = text; self.meeting = meeting
        self.savedAudio = savedAudio; self.finalPlayback = finalPlayback; self.speakers = speakers
        self.speakerAttribution = speakerAttribution
    }
}

struct ChatFinalPlaybackRange: Codable, Sendable, Equatable {
    let start: Double
    let end: Double
    var isValid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
            && end < Double(Int64.max / 1_000_000_000)
    }
}

struct ChatEvidenceReference: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let parentSegmentID: String
    let source: String
    let text: String
    let startUTF8: Int
    let endUTF8: Int
    let isFragment: Bool
    let meeting: LiveMeetingRange?
    let savedAudio: [LiveSavedAudioSlice]
    let finalPlayback: ChatFinalPlaybackRange?
    let speakers: [String]
    // No property default: synthesized Codable decodes older absent values as nil.
    let speakerAttribution: [ChatSpeakerAttributionSpan]?
    init(id: String, parentSegmentID: String, source: String, text: String, startUTF8: Int, endUTF8: Int,
         isFragment: Bool, meeting: LiveMeetingRange?, savedAudio: [LiveSavedAudioSlice],
         finalPlayback: ChatFinalPlaybackRange?, speakers: [String], speakerAttribution: [ChatSpeakerAttributionSpan]? = nil) {
        self.id = id; self.parentSegmentID = parentSegmentID; self.source = source; self.text = text
        self.startUTF8 = startUTF8; self.endUTF8 = endUTF8; self.isFragment = isFragment; self.meeting = meeting
        self.savedAudio = savedAudio; self.finalPlayback = finalPlayback; self.speakers = speakers
        self.speakerAttribution = speakerAttribution
    }
}

struct ChatAnswerBasis: Codable, Sendable, Equatable {
    enum Selection: String, Codable, Sendable { case allEligible, excerpts }
    let source: ChatTranscriptSource
    let route: ChatRouteBasis
    let language: OutputLanguage
    let evidence: [ChatEvidenceReference]
    let selection: Selection
    let eligibleSegmentCount: Int
    let scannedSegmentCount: Int
    let scanLimited: Bool
    let historyLimited: Bool
    let budget: ChatBudgetReceipt
    var label: String { source.label + (selection == .excerpts ? " · Selected excerpts" : "") }
}

enum ChatAnswerOutcome: String, Codable, Sendable {
    case streaming, completed, interrupted, truncated, limited, failed, unconfirmed
    var qualification: String? {
        switch self {
        case .streaming, .completed: nil
        case .interrupted: "Stopped answer"
        case .truncated: "Provider output limit reached"
        case .limited: "Response stopped at an application limit"
        case .failed: "Answer failed"
        case .unconfirmed: "Answer completion unconfirmed"
        }
    }
}

struct ChatReferenceResolution: Codable, Sendable, Equatable {
    let references: [ChatEvidenceReference]
    let invalidCount: Int
    var qualification: String? {
        if references.isEmpty { return "No supplied evidence references. Claims have not been verified." }
        if invalidCount > 0 { return "\(invalidCount) unavailable reference(s). Claims have not been verified." }
        return "References identify supplied evidence; claims have not been verified."
    }
}

enum ChatReferenceParser {
    private static let pattern = try! NSRegularExpression(pattern: #"\[\[ref:([^\]\r\n]{0,160})\]\]"#)
    static func resolve(_ text: String, basis: ChatAnswerBasis) -> ChatReferenceResolution {
        let supplied = Dictionary(basis.evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bounded = String(text.prefix(65_536))
        var refs: [ChatEvidenceReference] = [], seen: Set<String> = [], invalid = 0
        for match in pattern.matches(in: bounded, range: NSRange(bounded.startIndex..., in: bounded)) {
            guard let range = Range(match.range(at: 1), in: bounded) else { continue }
            let id = String(bounded[range])
            if let reference = supplied[id] {
                if seen.insert(id).inserted { refs.append(reference) }
            } else { invalid += 1 }
        }
        return .init(references: refs, invalidCount: invalid)
    }
    static func display(_ text: String, basis: ChatAnswerBasis) -> String {
        let resolution = resolve(text, basis: basis)
        let numbers = Dictionary(resolution.references.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        var value = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: value) else { continue }
            let marker = String(text[range])
            value.replaceSubrange(whole, with: numbers[marker].map { "[\($0)]" } ?? "[unavailable reference]")
        }
        return value
    }
}

/// A binding is supplied by the recording owner, never by generated text.
struct ChatPlaybackBinding: Sendable {
    let recordingID: UUID
    let captureSessionID: UUID?
    let mappingRevision: UInt64?
    let mapping: RecordingPlaybackMapping?
}

enum ChatReferencePlayback {
    static func seekSeconds(reference: ChatEvidenceReference, basis: ChatAnswerBasis, binding: ChatPlaybackBinding) -> Double? {
        guard basis.evidence.contains(reference), basis.source.recordingID == binding.recordingID,
              !reference.isFragment else { return nil }
        if basis.source.version == .final, let range = reference.finalPlayback, range.isValid { return range.start }
        guard let captureID = basis.source.captureSessionID, captureID == binding.captureSessionID,
              let revision = binding.mappingRevision, let mapping = binding.mapping else { return nil }
        // The current finalized master accepts only Task 2's exact raw-track copy.
        // AAC/DSP output and a track with no binding stay explicitly unseekable.
        for slice in reference.savedAudio where slice.mappingRevision == revision {
            guard case .track(let source) = slice.destination, slice.sampleRate > 0,
                  slice.startFrame >= 0, slice.frameCount > 0,
                  slice.startFrame <= Int64.max - slice.frameCount else { continue }
            let role: AudioTrackWriter.Role
            switch source { case .microphone: role = .mic; case .system: role = .system; case .finalMix: continue }
            let range = LiveAudioFrameRange(startFrame: slice.startFrame, frameCount: slice.frameCount, sampleRate: Double(slice.sampleRate))
            if let frames = mapping.masterFrames(for: role, savedTrack: range) {
                return Double(frames.startFrame) / Double(slice.sampleRate)
            }
        }
        return nil
    }
}
