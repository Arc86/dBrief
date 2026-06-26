import Foundation

/// A spoken-summary artifact persisted alongside a recording as
/// `<base>.spokensummary.json`, pointing at a sibling `<base>.spokensummary.m4a`
/// audio file. Caching the script lets a reopened recording replay (or skip the
/// AI rewrite on regenerate) without re-running anything.
struct SpokenSummary: Codable, Sendable, Equatable {
    var version: Int
    var script: String
    /// File name (not full path) of the sibling audio file, so it resolves
    /// relative to the JSON sidecar's directory regardless of where it moved.
    var audioFileName: String
    var voice: String?
    var language: String?
    /// `AIEngine.rawValue` that produced the script (for display/debugging).
    var engine: String
    var generatedAt: Date

    init(
        version: Int = 1,
        script: String,
        audioFileName: String,
        voice: String?,
        language: String?,
        engine: String,
        generatedAt: Date
    ) {
        self.version = version
        self.script = script
        self.audioFileName = audioFileName
        self.voice = voice
        self.language = language
        self.engine = engine
        self.generatedAt = generatedAt
    }
}
