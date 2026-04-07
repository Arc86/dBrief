import Foundation

struct RichTranscript: Codable, Sendable {
    var version: Int = 1
    var segments: [RichSegment]
    var speakerLabels: [SpeakerLabel] = []
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
