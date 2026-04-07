import Foundation
import OSLog

actor TranscriptStore {
    private let fileManager = FileManager.default

    // Primary URL-based throwing interface
    func load(from url: URL) async throws -> RichTranscript {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RichTranscript.self, from: data)
    }

    func save(_ transcript: RichTranscript, to url: URL) async throws {
        let data = try JSONEncoder().encode(transcript)
        try data.write(to: url, options: .atomic)
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

enum TranscriptStoreError: Error {
    case noSidecarURL
}
