import Foundation

struct RichTranscript: Codable, Sendable {
    var version: Int = 1
    var segments: [RichSegment]
    var speakerLabels: [SpeakerLabel] = []
    /// The speaker the user has marked as themselves ("this is me"). Persisted
    /// per recording so the highlight survives relaunch. Decoded leniently so
    /// transcripts written before this field still load.
    var meSpeakerId: String? = nil

    enum CodingKeys: String, CodingKey {
        case version, segments, speakerLabels, meSpeakerId
    }

    init(version: Int = 1, segments: [RichSegment], speakerLabels: [SpeakerLabel] = [], meSpeakerId: String? = nil) {
        self.version = version
        self.segments = segments
        self.speakerLabels = speakerLabels
        self.meSpeakerId = meSpeakerId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        segments = try c.decode([RichSegment].self, forKey: .segments)
        speakerLabels = try c.decodeIfPresent([SpeakerLabel].self, forKey: .speakerLabels) ?? []
        meSpeakerId = try c.decodeIfPresent(String.self, forKey: .meSpeakerId)
    }
}

struct RichSegment: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var text: String
    var originalText: String
    var tokens: [RichToken] = []
    var speakerId: String? = nil
    var isStarred: Bool = false
    var isEdited: Bool = false
}

struct RichToken: Codable, Sendable {
    var text: String
    var start: Double? = nil
    var end: Double? = nil
    var isFillerWord: Bool = false
}

struct SpeakerLabel: Codable, Sendable {
    var id: String
    var displayName: String
}
