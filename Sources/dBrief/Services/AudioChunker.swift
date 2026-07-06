@preconcurrency import AVFoundation
import Foundation

struct AudioChunk: Sendable {
    let index: Int
    let startSeconds: Double
    let endSeconds: Double
    let url: URL
}

actor AudioChunker {
    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(session: AVAssetExportSession) {
            self.session = session
        }
    }

    func chunkAudio(
        fileURL: URL,
        maxUploadBytes: Int,
        overlapSeconds: Double,
        tempDirectory: URL
    ) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let safeDuration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 0

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let estimatedBytesPerSecond: Double = {
            guard safeDuration > 0, fileSize > 0 else { return 128_000 / 8 } // fallback 16KB/s
            return Double(fileSize) / safeDuration
        }()

        let estimatedChunkDuration = Double(maxUploadBytes) / max(estimatedBytesPerSecond, 1)
        let chunkDuration = max(30, min(600, estimatedChunkDuration))
        let overlap = max(0, min(overlapSeconds, chunkDuration * 0.2))

        let effectiveDuration = safeDuration > 0 ? safeDuration : 120
        var currentStart = 0.0
        var chunks: [AudioChunk] = []
        var index = 0

        // Prefer an ffmpeg stream-copy (no re-encode) when the source codec can
        // land in an .m4a container as-is; fall back to AVAssetExportSession's
        // full AAC re-encode when ffmpeg is missing or the copy fails.
        let ffmpegPath = FFmpegLocator.resolve()
        let canStreamCopy = ["m4a", "mp4", "aac"].contains(fileURL.pathExtension.lowercased())

        while currentStart < effectiveDuration {
            let currentEnd = min(effectiveDuration, currentStart + chunkDuration)
            let outputURL = tempDirectory.appendingPathComponent("chunk_\(index).m4a")
            var copied = false
            if let ffmpegPath, canStreamCopy {
                copied = Self.streamCopyChunk(
                    ffmpegPath: ffmpegPath,
                    fileURL: fileURL,
                    startSeconds: currentStart,
                    endSeconds: currentEnd,
                    outputURL: outputURL
                )
            }
            if !copied {
                try await exportChunk(
                    asset: asset,
                    startSeconds: currentStart,
                    endSeconds: currentEnd,
                    outputURL: outputURL
                )
            }
            chunks.append(
                AudioChunk(
                    index: index,
                    startSeconds: currentStart,
                    endSeconds: currentEnd,
                    url: outputURL
                )
            )
            if currentEnd >= effectiveDuration { break }
            currentStart = max(0, currentEnd - overlap)
            index += 1
        }

        return chunks
    }

    /// Cut `[start, end]` out of the source with `-c copy` (packet-boundary cuts;
    /// the caller's chunk overlap absorbs the imprecision). Returns false on any
    /// failure so the caller can re-encode instead.
    private static func streamCopyChunk(
        ffmpegPath: String,
        fileURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        outputURL: URL
    ) -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        var arguments = [
            "-y",
            "-ss", String(format: "%.3f", startSeconds),
            "-t", String(format: "%.3f", endSeconds - startSeconds),
            "-i", fileURL.path,
            "-c", "copy",
            outputURL.path,
        ]
        if ffmpegPath == "/usr/bin/env" { arguments.insert("ffmpeg", at: 0) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64,
              size > 0
        else {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        return true
    }

    private func exportChunk(
        asset: AVAsset,
        startSeconds: Double,
        endSeconds: Double,
        outputURL: URL
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioChunkerError.exportFailed("Unable to create AVAssetExportSession.")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            end: CMTime(seconds: endSeconds, preferredTimescale: 600)
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ExportSessionBox(session: exporter)
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: box.session.error ?? AudioChunkerError.exportFailed("Chunk export failed."))
                case .cancelled:
                    continuation.resume(throwing: AudioChunkerError.exportFailed("Chunk export was cancelled."))
                default:
                    continuation.resume(throwing: AudioChunkerError.exportFailed("Chunk export ended in unexpected state."))
                }
            }
        }
    }
}

enum AudioChunkerError: Error, LocalizedError {
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportFailed(let message): message
        }
    }
}
