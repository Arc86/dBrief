import Foundation
import dBriefWire

/// Content-free cleanup authority. Each successful rewrite records its actual
/// physical result before the next effect; a same-byte replacement is foreign.
struct LiveHistoryRetention: Codable, Sendable {
    enum Effect: String, Codable, Sendable { case transcript, chat, remove }
    struct Step: Codable, Sendable {
        let original: RecordingDeletionAuthority.Item
        let effect: Effect
        let revision: UInt64?
        var result: RecordingDeletionAuthority.Item?
        var completed = false
    }
    let version: Int
    let identity: LiveSessionIdentity
    let intentID: UUID
    let authority: RecordingDeletionAuthority
    let generation: UUID?
    let cutoff: Date
    let linkedMarkdown: URL?
    var sourceRetired: Bool? = nil
    var sourceWasRetired: Bool { sourceRetired == true || steps.contains(where: { $0.effect == .transcript }) }
    var steps: [Step]
    var cleanupComplete: Bool

    var immutable: Self {
        var copy = self; copy.cleanupComplete = false
        for index in copy.steps.indices { copy.steps[index].result = nil; copy.steps[index].completed = false }
        return copy
    }
}

/// A portable snapshot carries its payload reservation until its actual last
/// consumer releases it. Private ledgers and absolute source paths are excluded.
struct LiveHistoryExport: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var version = Self.currentVersion
    let identity: LiveSessionIdentity
    let native: LiveTranscriptCheckpoint?
    let app: LiveTranscriptArtifact?
    let chat: ChatHistory?
    let sourceAvailable: Bool
    init(identity: LiveSessionIdentity, native: LiveTranscriptCheckpoint?, app: LiveTranscriptArtifact?, chat: ChatHistory?) {
        self.identity = identity; self.native = native; self.app = app; self.chat = chat
        sourceAvailable = native != nil || (app != nil && app?.sourceUnavailable != true)
    }
}

final class LiveHistoryExportSnapshot: Sendable {
    let data: Data
    let identity: LiveSessionIdentity
    private let reservation: LiveRecordingPayloadBudget.Lease
    init(data: Data, identity: LiveSessionIdentity, reservation: LiveRecordingPayloadBudget.Lease) {
        self.data = data; self.identity = identity; self.reservation = reservation
    }
}
