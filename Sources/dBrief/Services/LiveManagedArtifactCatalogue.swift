import Foundation
import dBriefWire

/// Content-free hints only. The ordered writer rereads and verifies all
/// authoritative payloads/ledgers before a hint can become an owner.
enum LiveManagedArtifactCatalogue {
    static let metadataBytes = 1 * 1_024 * 1_024
    static let inspectionBytes = 16 * 1_024 * 1_024
    static let hintLimit = 1_024
    static let hintByteLimit = 384 * 1_024
    struct Hint: Sendable, Equatable {
        let identity: LiveSessionIdentity
        let audioURL: URL?
        let deleted: Bool
        var charge: Int { 256 + (audioURL?.absoluteString.utf8.count ?? 0) * 6 }
    }
    private struct Header: Decodable {
        let version: Int
        let identity: LiveSessionIdentity
        let audioURL: URL?
        let bindingGeneration: UUID?
        let generation: UUID?
        let phase: String?
        let intentID: UUID?
        let cleanupComplete: Bool?
    }
    static func inspect(root: URL) throws -> [UUID: Hint] {
        try LiveSessionArtifactStore.requireSafeParents(root.appendingPathComponent("probe"))
        var hints: [UUID: Hint] = [:], captures: Set<UUID> = [], audioOwners: [URL: UUID] = [:], bytes = 0, directories = 0
        try RecordingDeletionAuthority.scanChildren(root, includeHidden: true) { directory in
            guard let capture = UUID(uuidString: directory.lastPathComponent) else {
                let kind = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard kind.isSymbolicLink != true else { throw LiveArtifactError.unsafePath }
                // Ordinary files at this root are outside the managed namespace.
                // An unknown directory could contain renamed owned evidence.
                guard kind.isDirectory != true else { throw LiveArtifactError.corruptArtifact }
                return
            }
            directories += 1
            guard directories <= hintLimit, captures.insert(capture).inserted,
                  try RecordingDeletionAuthority.Stamp.read(directory, directory: true) != nil else { throw LiveArtifactError.artifactTooLarge }
            let hint = try inspect(directory: directory, capture: capture)
            guard hints[hint.identity.recordingID] == nil else { throw LiveArtifactError.wrongOwner }
            if let audio = hint.audioURL {
                let path = try RecordingDeletionAuthority.canonical(audio)
                guard audioOwners[path] == nil || audioOwners[path] == hint.identity.recordingID else { throw LiveArtifactError.wrongOwner }
                audioOwners[path] = hint.identity.recordingID
            }
            bytes += hint.charge
            guard bytes <= hintByteLimit else { throw LiveArtifactError.artifactTooLarge }
            hints[hint.identity.recordingID] = hint
        }
        return hints
    }
    private static func header(_ url: URL, maximum: Int = RecordingDeletionAuthority.ticketLimit) throws -> Header? {
        try LiveSessionArtifactStore.requireSafeParents(url)
        return try RecordingDeletionAuthority.readHeader(url, maximumBytes: maximum,
            tokenLimit: maximum > RecordingDeletionAuthority.ticketLimit ? 1_048_576 : 32_768)
    }
    private static func inspect(directory: URL, capture: UUID) throws -> Hint {
        if let deleted = try header(directory.appendingPathComponent("deletion.json")) {
            guard [1, 2, 3].contains(deleted.version), deleted.identity.captureSessionID == capture,
                  deleted.version == 1 ? deleted.intentID == nil : deleted.intentID != nil && deleted.cleanupComplete != nil,
                  deleted.version == 3 ? deleted.audioURL != nil : (deleted.audioURL == nil) == (deleted.generation == nil) else { throw LiveArtifactError.corruptArtifact }
            try validateAudio(deleted.audioURL, directory: directory)
            return .init(identity: deleted.identity, audioURL: deleted.audioURL, deleted: true)
        }
        let binding = try header(directory.appendingPathComponent("binding.json"))
        if let binding {
            guard binding.version == 1, binding.generation != nil, ["prepared", "committed"].contains(binding.phase ?? ""),
                  binding.audioURL != nil else { throw LiveArtifactError.corruptArtifact }
            try validateAudio(binding.audioURL, directory: directory)
        }
        var owner = binding?.identity
        for (name, maximum, versions) in [("live-transcript.json", 3 * 1_024 * 1_024, [1, 2]),
                                         ("chat.json", LiveRecordingArtifactOwner.chatHistoryLimit, [2])] {
            let source = try header(directory.appendingPathComponent(name), maximum: maximum)
            let targetURL = binding?.audioURL?.deletingPathExtension().appendingPathExtension(name)
            let target = try targetURL.flatMap { try header($0, maximum: maximum) }
            for (value, expected) in [(source, Optional<UUID>.none), (target, binding?.generation)] {
                guard let value else { continue }
                guard versions.contains(value.version), value.identity.captureSessionID == capture,
                      owner == nil || owner == value.identity, value.bindingGeneration == expected else { throw LiveArtifactError.wrongOwner }
                owner = value.identity
            }
        }
        guard let owner, owner.captureSessionID == capture else { throw LiveArtifactError.corruptArtifact }
        return .init(identity: owner, audioURL: binding?.audioURL, deleted: false)
    }
    private static func validateAudio(_ audio: URL?, directory: URL) throws {
        guard let audio else { return }
        guard RecordingDeletionAuthority.isNormalizedFileURL(audio),
              RetentionCleanup.audioExtensions.contains(audio.pathExtension.lowercased()),
              !audio.path.hasPrefix(directory.path + "/") else { throw LiveArtifactError.unsafePath }
        try LiveSessionArtifactStore.requireSafeParents(audio)
    }
}
