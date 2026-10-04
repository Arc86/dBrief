import Foundation
import OSLog

actor TranscriptStore {
    private let fileManager = FileManager.default
    private let beforeOwnedSave: @Sendable () async -> Void
    private let afterOwnedSave: @Sendable () async -> Void
    init(beforeOwnedSave: @escaping @Sendable () async -> Void = {}, afterOwnedSave: @escaping @Sendable () async -> Void = {}) {
        self.beforeOwnedSave = beforeOwnedSave; self.afterOwnedSave = afterOwnedSave
    }

    func loadOwned(from url: URL, order: LiveSavedTranscriptOrder, validity: RecordingDerivativeValidity,
                   generation: RecordingDerivativeValidity, deletionAdmission: RecordingDerivativeValidity? = nil) async throws -> (RichTranscript, LiveSavedTranscriptOrder.Receipt) {
        try RecordingResultMutation.withTransaction {
            let read = { try order.read(at: url) { try generation.withValidResult { try validity.withValidResult { try self.loadValue(from: url) } } } }
            if let deletionAdmission { return try deletionAdmission.withValidResult(read) }
            return try read()
        }
    }
    func saveOwned(_ transcript: RichTranscript, to url: URL, order: LiveSavedTranscriptOrder,
                   validity: RecordingDerivativeValidity, generation: RecordingDerivativeValidity,
                   deletionAdmission: RecordingDerivativeValidity? = nil,
                   replacing expected: RichTranscript? = nil) async throws -> LiveSavedTranscriptOrder.Receipt {
        await beforeOwnedSave()
        let receipt = try RecordingResultMutation.withWrite(to: url) {
            let write = { try order.save(at: url) {
                try generation.withValidResult {
                    try validity.withValidResult {
                        if let expected, try self.loadValue(from: url) != expected { throw TranscriptStoreError.changedDuringReview }
                        try self.saveValue(transcript, to: url)
                    }
                }
            } }
            if let deletionAdmission { return try deletionAdmission.withValidResult(write) }
            return try write()
        }
        await afterOwnedSave()
        return receipt
    }

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

    func save(_ transcript: RichTranscript, to url: URL, validity: RecordingDerivativeValidity? = nil,
              generation: RecordingDerivativeValidity? = nil) async throws {
        try saveValue(transcript, to: url, validity: validity, generation: generation)
    }

    /// Compare and replace without an actor suspension between the comparison
    /// and write, so review cannot overwrite edits saved after its snapshot.
    func save(_ transcript: RichTranscript, to url: URL, replacing expected: RichTranscript) throws {
        guard try loadValue(from: url) == expected else { throw TranscriptStoreError.changedDuringReview }
        try saveValue(transcript, to: url)
    }

    private func saveValue(_ transcript: RichTranscript, to url: URL, validity: RecordingDerivativeValidity? = nil,
                           generation: RecordingDerivativeValidity? = nil) throws {
        try Task.checkCancellation()
        guard transcript.version == RichTranscript.currentVersion else {
            throw TranscriptStoreError.unsupportedVersion(transcript.version)
        }
        let data = try JSONEncoder().encode(transcript)
        try Task.checkCancellation()
        try RecordingResultMutation.withWrite(to: url) {
            try Task.checkCancellation()
            let write = { if let validity { try validity.withValidResult { try data.write(to: url, options: .atomic) } }
                else { try data.write(to: url, options: .atomic) } }
            if let generation { try generation.withValidResult(write) } else { try write() }
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

    func save(_ transcript: RichTranscript, for recording: Recording) async throws {
        let url = try await sidecarURL(for: recording)
        try await save(transcript, to: url)
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

enum TranscriptStoreError: Error, LocalizedError {
    case noSidecarURL
    case unsupportedVersion(Int)
    case verificationFailed
    case changedDuringReview

    var errorDescription: String? {
        switch self {
        case .noSidecarURL:
            "Cannot determine the rich-transcript sidecar path."
        case .unsupportedVersion(let version):
            "Rich transcript version \(version) is not supported."
        case .verificationFailed:
            "The rich transcript could not be verified after saving."
        case .changedDuringReview:
            "The transcript changed during speaker review. Reload it and review the speakers again."
        }
    }
}
