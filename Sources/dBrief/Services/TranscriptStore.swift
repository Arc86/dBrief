import Foundation
import OSLog

actor TranscriptStore {
    private let fileManager = FileManager.default

    // Primary URL-based throwing interface
    func load(from url: URL) async throws -> RichTranscript {
        let data = try Data(contentsOf: url)
        let transcript = try JSONDecoder().decode(RichTranscript.self, from: data)
        guard transcript.version == RichTranscript.currentVersion else {
            throw TranscriptStoreError.unsupportedVersion(transcript.version)
        }
        return transcript
    }

    func save(_ transcript: RichTranscript, to url: URL) async throws {
        guard transcript.version == RichTranscript.currentVersion else {
            throw TranscriptStoreError.unsupportedVersion(transcript.version)
        }
        let data = try JSONEncoder().encode(transcript)
        try data.write(to: url, options: .atomic)
        let verified = try JSONDecoder().decode(
            RichTranscript.self,
            from: Data(contentsOf: url)
        )
        guard verified == transcript else {
            throw TranscriptStoreError.verificationFailed
        }
    }

    // Convenience Recording-based overloads
    func load(for recording: Recording) async throws -> RichTranscript {
        let url = try await sidecarURL(for: recording)
        return try await load(from: url)
    }

    func save(_ transcript: RichTranscript, for recording: Recording) async throws {
        let url = try await sidecarURL(for: recording)
        try await save(transcript, to: url)
    }

    func exists(for recording: Recording) async -> Bool {
        guard let url = await MainActor.run(body: { recording.transcriptSidecarURL }) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func delete(for recording: Recording) async throws {
        let url = try await sidecarURL(for: recording)
        try fileManager.removeItem(at: url)
    }

    private func sidecarURL(for recording: Recording) async throws -> URL {
        let url = await MainActor.run(body: { recording.transcriptSidecarURL })
        guard let url else { throw TranscriptStoreError.noSidecarURL }
        return url
    }
}

enum TranscriptStoreError: Error, LocalizedError {
    case noSidecarURL
    case unsupportedVersion(Int)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .noSidecarURL:
            "Cannot determine the rich-transcript sidecar path."
        case .unsupportedVersion(let version):
            "Rich transcript version \(version) is not supported."
        case .verificationFailed:
            "The rich transcript could not be verified after saving."
        }
    }
}
