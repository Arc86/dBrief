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
        try Task.checkCancellation()
        guard maxUploadBytes > 0 else { throw AudioChunkerError.exportFailed("The upload byte budget must be positive.") }
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
        var chunkDuration = max(30, min(600, estimatedChunkDuration))
        let requestedOverlap = overlapSeconds.isFinite ? max(0, overlapSeconds) : 0

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
            try Task.checkCancellation()
            let outputURL = tempDirectory.appendingPathComponent("chunk_\(index).m4a")
            var currentEnd: Double
            var splitAttempts = 0
            while true {
                try Task.checkCancellation()
                currentEnd = min(effectiveDuration, currentStart + chunkDuration)
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
                try Task.checkCancellation()
                let bytes = try RemoteUploadPolicy.fileByteCount(outputURL)
                guard bytes > 0 else { throw AudioChunkerError.exportFailed("An exported audio chunk was empty.") }
                if bytes <= Int64(maxUploadBytes) { break }

                try FileManager.default.removeItem(at: outputURL)
                splitAttempts += 1
                let attemptedDuration = currentEnd - currentStart
                guard splitAttempts < 10, attemptedDuration > 1 else {
                    throw AudioChunkerError.sizeLimitUnreachable(maxUploadBytes)
                }
                // Original bitrate and output bitrate can differ dramatically.
                // Measure the actual export, halve its duration, and retry a
                // bounded number of times. Keep the shorter duration thereafter.
                chunkDuration = max(1, attemptedDuration / 2)
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
            // Recompute overlap after shrinking so even a large configured
            // overlap cannot prevent forward progress or create a time gap.
            let overlap = min(requestedOverlap, (currentEnd - currentStart) * 0.2)
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
    case sizeLimitUnreachable(Int)

    var errorDescription: String? {
        switch self {
        case .exportFailed(let message): message
        case .sizeLimitUnreachable(let bytes):
            "Could not fit an audio chunk within the \(bytes)-byte upload limit. Compress the recording or choose another endpoint. The original audio has been kept."
        }
    }
}
