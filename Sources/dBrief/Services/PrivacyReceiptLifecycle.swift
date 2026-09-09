import Foundation

/// Ownership checks shared by explicit deletion, discard, and retention. A
/// receipt belongs to the master and every numbered segment, regardless of age.
enum PrivacyReceiptLifecycle {
    static func recordingID(for audioURL: URL) -> UUID? {
        struct Identity: Decodable { let recordingID: UUID? }
        let metadata = audioURL.deletingPathExtension().appendingPathExtension("json")
        guard let handle = try? FileHandle(forReadingFrom: metadata) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return (try? JSONDecoder().decode(Identity.self, from: data))?.recordingID
    }

    static func receiptURL(for audioURL: URL) -> URL {
        // A segment can itself be opened/processed as a recording. Its own
        // evidence must never be redirected to a parent merely by filename.
        PrivacyReceiptStore.sidecarURL(for: audioURL)
    }

    static func canRemoveDiscardedEvidence(audioURL: URL, finalized: Bool, knownFiles: [URL],
                                           removedSessionDirectory: URL?, fileManager: FileManager = .default) -> Bool {
        if !finalized, let removedSessionDirectory {
            let prefix = removedSessionDirectory.standardizedFileURL.path + "/"
            // Successful removal of this owned scratch directory is direct
            // evidence of deletion even though enumeration now returns ENOENT.
            if !knownFiles.isEmpty, knownFiles.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(prefix) }) { return true }
        }
        return (try? hasSurvivingAudio(for: receiptURL(for: audioURL), fileManager: fileManager)) == false
    }

    /// Throws if the folder cannot be inspected. Offline storage is never
    /// interpreted as proof that the recording has been deleted.
    static func hasSurvivingAudio(for receiptURL: URL, fileManager: FileManager = .default) throws -> Bool {
        let base = receiptURL.deletingPathExtension().deletingPathExtension().lastPathComponent
        let siblings = try fileManager.contentsOfDirectory(at: receiptURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        return siblings.contains { url in
            guard RecordingDiscovery.supportedExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let stem = url.deletingPathExtension().lastPathComponent
            if stem == base { return true }
            let prefix = base + "_part"
            guard stem.hasPrefix(prefix) else { return false }
            let suffix = stem.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
    }
}
