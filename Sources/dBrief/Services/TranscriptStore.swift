import Foundation
import OSLog

actor TranscriptStore {
    private let fileManager = FileManager.default
    private let logger = Logger.recording

    func load(for recording: Recording) async -> RichTranscript? {
        let url = await MainActor.run { recording.transcriptSidecarURL }
        guard let url else { return nil }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let transcript = try JSONDecoder().decode(RichTranscript.self, from: data)
            logger.info("Loaded rich transcript from \(url.lastPathComponent, privacy: .public)")
            return transcript
        } catch {
            logger.error("Failed to load rich transcript: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ transcript: RichTranscript, for recording: Recording) async {
        let url = await MainActor.run { recording.transcriptSidecarURL }
        guard let url else { return }
        do {
            let data = try JSONEncoder().encode(transcript)
            try data.write(to: url, options: .atomic)
            logger.info("Saved rich transcript to \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Failed to save rich transcript: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(for recording: Recording) async {
        let url = await MainActor.run { recording.transcriptSidecarURL }
        guard let url else { return }
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
            logger.info("Deleted rich transcript at \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Failed to delete rich transcript: \(error.localizedDescription, privacy: .public)")
        }
    }

    func exists(for recording: Recording) async -> Bool {
        let url = await MainActor.run { recording.transcriptSidecarURL }
        guard let url else { return false }
        return fileManager.fileExists(atPath: url.path)
    }
}
