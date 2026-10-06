import AVFoundation
import Foundation
import dBriefWire
import os

private let log = Logger.localTranscription

/// Which engine produces the live preview for one capture (frozen at start).
enum LiveEngineSelection: Sendable, Equatable {
    case appleSpeech
    /// Batch Parakeet on short speech chunks; `chunkSeconds` is the target length.
    case parakeet(variant: String, chunkSeconds: Double)
}

/// Helper-process seam for live Parakeet, injectable for tests.
struct ParakeetLiveBackend: Sendable {
    var isModelReady: @Sendable (_ variant: String) async -> Bool
    var transcribe: @Sendable (_ chunk: URL, _ variant: String) async throws -> TranscriptionResult

    static func live(_ service: ParakeetTranscriptionService) -> Self {
        .init(isModelReady: { await service.isModelDownloaded(variant: $0) },
              transcribe: { try await service.transcribeLiveChunk(fileURL: $0, modelVariant: $1) })
    }
}

/// One live channel (mic or system) transcribed by Parakeet: the channel's audio
/// is resampled to 16 kHz mono, cut at speech pauses by `LiveSpeechChunker`, and
/// each chunk is transcribed in the ML helper as a short WAV. Results arrive as
/// finalized segments only (Parakeet has no partial hypotheses), roughly one
/// chunk behind the speaker.
enum ParakeetLiveChannel {
    /// Consecutive helper failures after which the channel stops transcribing
    /// (audio is still drained) instead of relaunching a crashing helper per chunk.
    static let maxConsecutiveFailures = 3
    static let sampleRate = 16_000.0

    static func run(_ request: LiveTranscriptionService.ChannelRequest,
                    variant: String, chunkSeconds: Double, backend: ParakeetLiveBackend) async {
        let speaker = request.channel.rawValue
        guard await backend.isModelReady(variant) else {
            let name = ParakeetModelInfo.find(variant).displayName
            request.onStatus("Live Parakeet needs \(name). Download it in Settings → Transcription.")
            return
        }
        // One receipt entry per channel, not per chunk (receipts are capped).
        do {
            try await PrivacyTrace.perform(.init(stage: .liveTranscription, data: [.recordingAudio, .metadata],
                                                 destination: .local(provider: .parakeet, model: variant))) {
                try await Self.transcribe(request, variant: variant, chunkSeconds: chunkSeconds, backend: backend)
            }
        } catch {
            // Stop is terminal and prompt (CancellationError); anything else is logged.
            if !(error is CancellationError) {
                log.error("Live Parakeet \(speaker, privacy: .public) audio failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Returns at end of audio once queued chunks are done; throws on cancel
    /// without waiting for an in-flight helper call (it can't be cancelled) —
    /// the worker then drops that result and cleans up on its own.
    private static func transcribe(_ request: LiveTranscriptionService.ChannelRequest, variant: String,
                                   chunkSeconds: Double, backend: ParakeetLiveBackend) async throws {
        let speaker = request.channel.rawValue
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                               channels: 1, interleaved: false) else {
            throw AudioConversionError.unsupportedFormat
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dBrief-live-\(UUID().uuidString)", isDirectory: true)
        let (chunks, chunkSink) = AsyncStream<LiveSpeechChunker.Chunk>.makeStream(bufferingPolicy: .unbounded)

        // Transcription runs beside capture so a slow helper (e.g. busy with a
        // previous recording's job) never stalls audio intake; chunks queue up.
        let worker = Task {
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                log.error("Live Parakeet temp folder failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            request.onStatus("Loading Parakeet…")
            var failures = 0
            for await chunk in chunks {
                guard !Task.isCancelled else { break }
                guard failures < Self.maxConsecutiveFailures else { continue }
                let url = directory.appendingPathComponent("\(chunk.startSample).wav")
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    try Self.writeWAV(chunk.samples, to: url)
                    let result = try await backend.transcribe(url, variant)
                    failures = 0
                    guard !Task.isCancelled else { break }
                    let segments = Self.liveSegments(from: result, offset: Double(chunk.startSample) / Self.sampleRate,
                                                     duration: Double(chunk.samples.count) / Self.sampleRate, speaker: speaker)
                    if !segments.isEmpty { request.onFinalized(segments) }
                } catch {
                    guard !Task.isCancelled else { break }
                    failures += 1
                    log.error("Live Parakeet \(speaker, privacy: .public) chunk failed: \(error.localizedDescription, privacy: .public)")
                    if failures == Self.maxConsecutiveFailures {
                        request.onStatus("Live transcript paused: \(error.localizedDescription)")
                    }
                }
            }
        }

        var chunker = LiveSpeechChunker(configuration: .forTarget(seconds: chunkSeconds))
        let conversion = LiveAudioConversion(targetFormat: targetFormat)
        do {
            for await wrapped in request.audio {
                try Task.checkCancellation()
                for buffer in try conversion.convert(wrapped.buffer) {
                    for chunk in chunker.append(samples(of: buffer)) { chunkSink.yield(chunk) }
                }
            }
            try Task.checkCancellation()
            for buffer in try conversion.finish() {
                for chunk in chunker.append(samples(of: buffer)) { chunkSink.yield(chunk) }
            }
            if let tail = chunker.flush() { chunkSink.yield(tail) }
            chunkSink.finish()
            // Normal end of audio: let queued chunks finish, unless Stop arrives.
            await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
        } catch {
            chunkSink.finish()
            worker.cancel()
            throw error
        }
    }

    /// Maps a chunk's result onto the recording timeline. Falls back to one
    /// segment spanning the chunk when Parakeet returned text without timings.
    static func liveSegments(from result: TranscriptionResult, offset: Double, duration: Double,
                             speaker: String) -> [LiveTranscriptSegment] {
        let timed = result.segments.compactMap { segment -> LiveTranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LiveTranscriptSegment(start: offset + segment.start, end: offset + segment.end,
                                         text: text, speaker: speaker)
        }
        if !timed.isEmpty { return timed }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [LiveTranscriptSegment(start: offset, end: offset + duration, text: text, speaker: speaker)]
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    /// Writes 16 kHz mono 16-bit PCM — small, and loadable by FluidAudio as-is.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw AudioConversionError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
