import Foundation
import CryptoKit

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
    /// Legacy items use the current profile. New items retain their selected
    /// profile identity even after their temporary automatic route ends.
    var profileID: UUID? = nil

    init(
        id: UUID = UUID(),
        transcribe: Bool,
        summary: Bool,
        actionItems: Bool,
        tags: Bool,
        titleWasUserProvided: Bool = false,
        autoQueued: Bool = false,
        profileID: UUID? = nil
    ) {
        self.id = id
        self.transcribe = transcribe
        self.summary = summary
        self.actionItems = actionItems
        self.tags = tags
        self.titleWasUserProvided = titleWasUserProvided
        self.autoQueued = autoQueued
        self.profileID = profileID
    }

    private enum CompatibilityKeys: String, CodingKey { case version }

    init(from decoder: Decoder) throws {
        let header = try decoder.container(keyedBy: CompatibilityKeys.self)
        guard try header.decodeIfPresent(Int.self, forKey: .version) ?? 1 == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        transcribe = try c.decode(Bool.self, forKey: .transcribe)
        summary = try c.decode(Bool.self, forKey: .summary)
        actionItems = try c.decode(Bool.self, forKey: .actionItems)
        tags = try c.decode(Bool.self, forKey: .tags)
        titleWasUserProvided = try c.decodeIfPresent(Bool.self, forKey: .titleWasUserProvided) ?? false
        autoQueued = try c.decodeIfPresent(Bool.self, forKey: .autoQueued) ?? false
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
    }

    /// Legacy queue files have no ID. A deterministic path identity prevents a
    /// new recovery job being created each time that same marker is scanned.
    static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        return try decode(data, from: url)
    }

    static func decode(_ data: Data, from url: URL) throws -> Self {
        var item = try JSONDecoder().decode(Self.self, from: data)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if payload?["id"] == nil {
            let bytes = Array(SHA256.hash(data: Data(url.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).prefix(16))
            item.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        return item
    }
}
