import Foundation
import OSLog

actor TranscriptStore {
    private let fileManager = FileManager.default

    // Primary URL-based throwing interface
    func load(from url: URL) async throws -> RichTranscript {
        try loadValue(from: url)
    }

    private func loadValue(from url: URL) throws -> RichTranscript {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        let transcript = try JSONDecoder().decode(RichTranscript.self, from: data)
        guard transcript.version == RichTranscript.currentVersion else {
            throw TranscriptStoreError.unsupportedVersion(transcript.version)
        }
        return transcript
    }

    func save(_ transcript: RichTranscript, to url: URL) async throws {
        try saveValue(transcript, to: url)
    }

    /// Compare and replace without an actor suspension between the comparison
    /// and write, so review cannot overwrite edits saved after its snapshot.
    func save(_ transcript: RichTranscript, to url: URL, replacing expected: RichTranscript) throws {
        guard try loadValue(from: url) == expected else { throw TranscriptStoreError.changedDuringReview }
        try saveValue(transcript, to: url)
    }

    /// `audioURL`: when given, the write is skipped (`recordingDeleted`) once that audio is
    /// gone, checked under the same lock deletion holds, so a late edit can't recreate the
    /// sidecar of a deleted recording.
    private func saveValue(_ transcript: RichTranscript, to url: URL, audioURL: URL? = nil) throws {
        try Task.checkCancellation()
        guard transcript.version == RichTranscript.currentVersion else {
            throw TranscriptStoreError.unsupportedVersion(transcript.version)
        }
        let data = try JSONEncoder().encode(transcript)
        try Task.checkCancellation()
        try RecordingResultMutation.withWrite(to: url) {
            try Task.checkCancellation()
            if let audioURL, !fileManager.fileExists(atPath: audioURL.path) {
                throw TranscriptStoreError.recordingDeleted
            }
            try data.write(to: url, options: .atomic)
        }
        let verified = try JSONDecoder().decode(
            RichTranscript.self,
            from: Data(contentsOf: url)
        )
        guard verified == transcript else {
            throw TranscriptStoreError.verificationFailed
        }
        RecordingLibraryChange.notify()
    }

    // Convenience Recording-based overloads
    func load(for recording: Recording) async throws -> RichTranscript {
        let url = try await sidecarURL(for: recording)
        return try await load(from: url)
    }

    /// Saves next to the recording's audio, and only while that audio still exists.
    func save(_ transcript: RichTranscript, for recording: Recording) async throws {
        let url = try await sidecarURL(for: recording)
        let audioURL = await MainActor.run(body: { recording.finalizedAudioURL })
        try saveValue(transcript, to: url, audioURL: audioURL)
    }

    func exists(for recording: Recording) async -> Bool {
        guard let url = await MainActor.run(body: { recording.transcriptSidecarURL }) else { return false }
        return exists(at: url)
    }

    func exists(at url: URL) -> Bool {
        return fileManager.fileExists(atPath: url.path)
    }

    func delete(for recording: Recording) async throws {
        let url = try await sidecarURL(for: recording)
        try RecordingResultMutation.withWrite(to: url) { try fileManager.removeItem(at: url) }
        RecordingLibraryChange.notify()
    }

    private func sidecarURL(for recording: Recording) async throws -> URL {
        let url = await MainActor.run(body: { recording.transcriptSidecarURL })
        guard let url else { throw TranscriptStoreError.noSidecarURL }
        return url
    }
}

enum TranscriptStoreError: Error, LocalizedError, Equatable {
    case noSidecarURL
    case unsupportedVersion(Int)
    case verificationFailed
    case changedDuringReview
    case recordingDeleted

    var errorDescription: String? {
        switch self {
        case .noSidecarURL:
            String(localized: "Cannot determine the rich-transcript sidecar path.")
        case .unsupportedVersion(let version):
            String(localized: "Rich transcript version \(version) is not supported.")
        case .verificationFailed:
            String(localized: "The rich transcript could not be verified after saving.")
        case .changedDuringReview:
            String(localized: "The transcript changed during speaker review. Reload it and review the speakers again.")
        case .recordingDeleted:
            String(localized: "The recording was deleted, so the transcript was not saved.")
        }
    }
}
