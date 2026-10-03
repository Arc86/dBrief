import Foundation
import dBriefWire

/// Apple preview IDs are deliberately copied rather than using the wire
/// segment's decoder, which regenerates UUIDs. Timing remains unqualified.
struct LiveLegacyTranscriptValue: Codable, Sendable, Equatable {
    let id: UUID
    let text: String
    let speaker: String?
    init(_ value: LiveTranscriptSegment) { id = value.id; text = value.text; speaker = value.speaker }
}

struct LiveAppFinalPublication: Codable, Sendable, Equatable {
    struct Segment: Codable, Sendable, Equatable {
        let id: UUID
        let text: String
        let speaker: String?
        let playback: ChatFinalPlaybackRange?
    }
    let id: UUID
    let revision: UInt64
    let segments: [Segment]
    let speakerLabels: [SpeakerLabel]
    var fallbackText: String? = nil
    init(id: UUID, revision: UInt64, transcript: RichTranscript, fallbackText: String? = nil) {
        self.id = id; self.revision = revision; self.fallbackText = fallbackText
        speakerLabels = transcript.speakerLabels
        segments = transcript.segments.map {
            let playback = ChatFinalPlaybackRange(start: $0.start, end: $0.end)
            return .init(id: $0.id, text: $0.text, speaker: $0.speakerId, playback: playback.isValid ? playback : nil)
        }
    }

    func context(identity: LiveSessionIdentity) -> TranscriptContextSnapshot {
        let source = ChatTranscriptSource(recordingID: identity.recordingID, captureSessionID: identity.captureSessionID,
            version: .final, publicationID: id, publicationRevision: revision, textRevision: revision,
            annotationRevision: revision, cutoffNanoseconds: nil, scope: .completeFinal,
            speakerLegend: speakerLabels, liveMetadata: nil)
        var values: [ChatTranscriptSegment] = segments.map {
            .init(id: $0.id.uuidString.lowercased(), source: "finalMix", text: $0.text,
                finalPlayback: $0.playback, speakers: $0.speaker.map { [$0] } ?? [])
        }
        if values.isEmpty, let fallbackText, !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values = [.init(id: "\(id.uuidString.lowercased()):text", source: "finalMix", text: fallbackText)]
        }
        return .init(source: source, segments: values)
    }

    func validate() throws {
        guard revision > 0, segments.count <= 100_000, speakerLabels.count <= 100_000,
              Set(segments.map(\.id)).count == segments.count,
              Set(speakerLabels.map(\.id)).count == speakerLabels.count,
              segments.allSatisfy({ $0.playback?.isValid ?? true }),
              speakerLabels.allSatisfy({ !$0.id.isEmpty && !$0.displayName.isEmpty }) else {
            throw LiveArtifactError.corruptArtifact
        }
    }
}

/// Version 2 is an app envelope; the qualified native checkpoint stays v1.
/// Exactly one captured source is present, even when it contains no text.
struct LiveTranscriptArtifact: Codable, Sendable, Equatable {
    static let currentVersion = 2
    var version = Self.currentVersion
    let identity: LiveSessionIdentity
    let revision: UInt64
    var native: LiveTranscriptCheckpoint? = nil
    var legacy: [LiveLegacyTranscriptValue]? = nil
    var captureClosed = false
    var finalPublication: LiveAppFinalPublication? = nil
    var bindingGeneration: UUID? = nil

    func validate() throws {
        guard version == Self.currentVersion else { throw LiveArtifactError.unsupportedVersion }
        guard (native == nil) != (legacy == nil) else { throw LiveArtifactError.corruptArtifact }
        if let native {
            try native.validate()
            guard native.identity == identity, native.bindingGeneration == nil else { throw LiveArtifactError.wrongOwner }
        }
        if let legacy {
            guard legacy.count <= 100_000, Set(legacy.map(\.id)).count == legacy.count,
                  legacy.allSatisfy({ $0.text.utf8.count <= 65_536 && ($0.speaker?.utf8.count ?? 0) <= 256 }) else {
                throw LiveArtifactError.corruptArtifact
            }
        }
        if let finalPublication {
            guard captureClosed else { throw LiveArtifactError.corruptArtifact }
            try finalPublication.validate()
        }
    }

    func legacyContext() throws -> TranscriptContextSnapshot {
        guard let legacy else { throw LiveArtifactError.corruptArtifact }
        let labels = Set(legacy.compactMap(\.speaker)).sorted().map { SpeakerLabel(id: $0, displayName: $0) }
        let source = ChatTranscriptSource(recordingID: identity.recordingID, captureSessionID: identity.captureSessionID,
            version: .live, publicationID: nil, publicationRevision: nil, textRevision: revision,
            annotationRevision: nil, cutoffNanoseconds: nil, scope: nil, speakerLegend: labels, liveMetadata: nil)
        return .init(source: source, segments: legacy.map {
            .init(id: $0.id.uuidString.lowercased(), source: "legacy", text: $0.text, speakers: $0.speaker.map { [$0] } ?? [])
        })
    }
    func finalContext() -> TranscriptContextSnapshot? { finalPublication?.context(identity: identity) }
}

/// Retains the original schema when canonicalizing v1 binding vectors. Merely
/// reading an old artifact must not change its journal's content fingerprint.
enum LiveTranscriptArtifactCodec {
    enum Value: Sendable {
        case native(LiveTranscriptCheckpoint), app(LiveTranscriptArtifact)
        var identity: LiveSessionIdentity { switch self { case .native(let v): v.identity; case .app(let v): v.identity } }
        var revision: UInt64 { switch self { case .native(let v): v.revision; case .app(let v): v.revision } }
        var bindingGeneration: UUID? { switch self { case .native(let v): v.bindingGeneration; case .app(let v): v.bindingGeneration } }
        var native: LiveTranscriptCheckpoint? { switch self { case .native(let v): v; case .app(let v): v.native } }
        var app: LiveTranscriptArtifact? { if case .app(let v) = self { v } else { nil } }
        func encoded(generation: UUID?, limit: Int) throws -> Data {
            switch self {
            case .native(var v): v.bindingGeneration = generation; return try LiveArtifactEncoding.encode(v, limit: limit)
            case .app(var v): v.bindingGeneration = generation; return try LiveArtifactEncoding.encode(v, limit: limit)
            }
        }
    }
    static func decode(_ data: Data) throws -> Value {
        struct Header: Decodable { let version: Int }
        do {
            let decoder = JSONDecoder()
            switch try decoder.decode(Header.self, from: data).version {
            case 1:
                let value = try decoder.decode(LiveTranscriptCheckpoint.self, from: data); try value.validate(); return .native(value)
            case 2:
                let value = try decoder.decode(LiveTranscriptArtifact.self, from: data); try value.validate(); return .app(value)
            default: throw LiveArtifactError.unsupportedVersion
            }
        } catch let error as LiveArtifactError { throw error }
        catch let error as LiveTranscriptCheckpoint.Failure { throw error }
        catch { throw LiveArtifactError.corruptArtifact }
    }
}
