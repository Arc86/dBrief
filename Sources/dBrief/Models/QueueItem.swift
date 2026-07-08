import Foundation

struct QueueItem: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var transcribe: Bool
    var summary: Bool
    var actionItems: Bool
    var tags: Bool
    /// Preserves the user's custom-title choice across the queue so AI title generation
    /// stays suppressed when the item is processed later. Defaults false for old queue files.
    var titleWasUserProvided: Bool = false
    /// True when the item was auto-enqueued as overflow (a recording finished while another
    /// job was already processing) rather than explicitly deferred by the user via the
    /// "Queue" button. Only auto-queued items drain automatically when the current job
    /// finishes; user-deferred items wait for the manual "Process Queue" button. Defaults
    /// false for old queue files and for explicit "Queue for later".
    var autoQueued: Bool = false

    init(
        id: UUID = UUID(),
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool,
        titleWasUserProvided: Bool = false,
        autoQueued: Bool = false
    ) {
        self.id = id
        self.transcribe = transcribe
        self.summary = summary
        self.actionItems = actionItems
        self.tags = tags
        self.titleWasUserProvided = titleWasUserProvided
        self.autoQueued = autoQueued
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        transcribe = try c.decode(Bool.self, forKey: .transcribe)
        summary = try c.decode(Bool.self, forKey: .summary)
        actionItems = try c.decode(Bool.self, forKey: .actionItems)
        tags = try c.decode(Bool.self, forKey: .tags)
        titleWasUserProvided = try c.decodeIfPresent(Bool.self, forKey: .titleWasUserProvided) ?? false
        autoQueued = try c.decodeIfPresent(Bool.self, forKey: .autoQueued) ?? false
    }
}
