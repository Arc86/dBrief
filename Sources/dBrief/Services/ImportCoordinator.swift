import Foundation
import AVFoundation

/// Prepares finished audio without touching observable UI or starting processing.
/// Blocking file copies and metadata reads stay on this actor, off MainActor.
actor ImportCoordinator {
    struct PreparedImport: Sendable {
        let sourceURL: URL
        let date: Date
        let stagedURL: URL
        let fileSize: Int64
        let title: String
        var duration: Double = 0
    }

    struct FileAccess: Sendable {
        var copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        var size: @Sendable (URL) -> Int64 = {
            let attributes = try? FileManager.default.attributesOfItem(atPath: $0.path)
            return (attributes?[.size] as? Int64) ?? 0
        }
        var exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        var remove: @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    }

    private let temporaryRoot: URL
    private let makeID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let files: FileAccess
    private let probe: @Sendable (URL) async -> Double
    private let download: @Sendable (String) async throws -> (URL, String)

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory,
         makeID: @escaping @Sendable () -> UUID = { UUID() },
         now: @escaping @Sendable () -> Date = { Date() },
         files: FileAccess = .init(),
         probe: @escaping @Sendable (URL) async -> Double = ImportCoordinator.probeDuration,
         download: (@Sendable (String) async throws -> (URL, String))? = nil) {
        self.temporaryRoot = temporaryRoot
        self.makeID = makeID
        self.now = now
        self.files = files
        self.probe = probe
        // Preserve the existing single downloader actor across requests.
        let downloader = YouTubeDownloadService()
        self.download = download ?? { try await downloader.downloadAudio(from: $0) }
    }

    func preparePickedFile(_ source: URL, title: String) throws -> PreparedImport {
        try stage(source, prefix: "import", title: title)
    }

    func prepareWatchedFile(_ source: URL) async throws -> PreparedImport {
        let prepared = try stage(source, prefix: "watched", title: source.deletingPathExtension().lastPathComponent)
        return try await withDuration(prepared, probing: prepared.stagedURL)
    }

    func prepareDownload(from value: String) async throws -> PreparedImport {
        try Task.checkCancellation()
        let (audio, title) = try await download(value)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = PreparedImport(sourceURL: audio, date: now(), stagedURL: audio, fileSize: files.size(audio),
            title: trimmed.isEmpty ? "youtube-video" : trimmed)
        return try await withDuration(prepared, probing: audio)
    }

    func durationSeconds(for url: URL) async -> Double {
        let seconds = await probe(url)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Call only before handing the stage to a Recording / ProcessingJobStore.
    /// A downloaded file is already owned; local imports own only their copy.
    func discard(_ prepared: PreparedImport) {
        files.remove(prepared.stagedURL)
    }

    private func stage(_ source: URL, prefix: String, title: String) throws -> PreparedImport {
        try Task.checkCancellation()
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let staged = temporaryRoot.appendingPathComponent("\(prefix)-\(makeID().uuidString)").appendingPathExtension(ext)
        // A collision must never give cleanup ownership of an existing file.
        guard !files.exists(staged) else { throw CocoaError(.fileWriteFileExists) }
        do {
            try files.copy(source, staged)
            try Task.checkCancellation()
            return PreparedImport(sourceURL: source, date: now(), stagedURL: staged, fileSize: files.size(source), title: title)
        } catch {
            // A failed exclusive copy may have encountered a destination created
            // after the preflight (or a dangling symlink). It is not ours to remove.
            let failure = error as NSError
            let collision = (failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteFileExists.rawValue)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(EEXIST))
            if !collision { files.remove(staged) }
            throw error
        }
    }

    private func withDuration(_ prepared: PreparedImport, probing url: URL) async throws -> PreparedImport {
        do {
            try Task.checkCancellation()
            var result = prepared
            result.duration = await durationSeconds(for: url)
            try Task.checkCancellation()
            return result
        } catch {
            discard(prepared)
            throw error
        }
    }

    private nonisolated static func probeDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}
