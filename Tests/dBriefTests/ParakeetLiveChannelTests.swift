import AVFoundation
import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Live Parakeet channel")
struct ParakeetLiveChannelTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _segments: [LiveTranscriptSegment] = []
        private var _statuses: [String] = []
        private var _calls: [(variant: String, existed: Bool, url: URL)] = []
        func add(_ segments: [LiveTranscriptSegment]) { lock.withLock { _segments += segments } }
        func status(_ text: String) { lock.withLock { _statuses.append(text) } }
        func call(_ url: URL, _ variant: String) {
            let existed = FileManager.default.fileExists(atPath: url.path)
            lock.withLock { _calls.append((variant, existed, url)) }
        }
        var segments: [LiveTranscriptSegment] { lock.withLock { _segments } }
        var statuses: [String] { lock.withLock { _statuses } }
        var calls: [(variant: String, existed: Bool, url: URL)] { lock.withLock { _calls } }
    }

    /// 48 kHz mono float buffers: `silence` s, then a tone for `speech` s, then `trailing` s silence.
    private static func audio(silence: Double, speech: Double, trailing: Double) -> AsyncStream<LiveAudioBuffer> {
        let rate = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let total = Int((silence + speech + trailing) * rate)
        let speechRange = Int(silence * rate)..<Int((silence + speech) * rate)
        var buffers: [LiveAudioBuffer] = []
        var index = 0
        while index < total {
            let count = min(4_800, total - index)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                let n = index + i
                buffer.floatChannelData![0][i] = speechRange.contains(n) ? Float(0.1 * sin(2 * Double.pi * 440 * Double(n) / rate)) : 0
            }
            buffers.append(LiveAudioBuffer(buffer))
            index += count
        }
        return AsyncStream { continuation in
            for buffer in buffers { continuation.yield(buffer) }
            continuation.finish()
        }
    }

    private static func request(_ audio: AsyncStream<LiveAudioBuffer>, _ recorder: Recorder) -> LiveTranscriptionService.ChannelRequest {
        .init(audio: audio, channel: .mic, language: "nl",
              onFinalized: { recorder.add($0) }, onVolatile: { _, _ in }, onStatus: { recorder.status($0) },
              engine: .parakeet(variant: "v3", chunkSeconds: 6))
    }

    @Test func chunkIsTranscribedAndPlacedOnTheRecordingTimeline() async throws {
        let recorder = Recorder()
        let backend = ParakeetLiveBackend(isModelReady: { _ in true }, transcribe: { url, variant in
            recorder.call(url, variant)
            return TranscriptionResult(text: "hallo daar", segments: [.init(start: 0.25, end: 1.2, text: " hallo daar ")])
        })
        await ParakeetLiveChannel.run(Self.request(Self.audio(silence: 2, speech: 1, trailing: 1.5), recorder),
                                      variant: "v3", chunkSeconds: 6, backend: backend)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.variant == "v3")
        #expect(recorder.calls.first?.existed == true)
        // Temp chunk files never outlive the channel.
        #expect(recorder.calls.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.deletingLastPathComponent().path) })
        let segment = try #require(recorder.segments.first)
        #expect(recorder.segments.count == 1)
        #expect(segment.text == "hallo daar")
        #expect(segment.speaker == "You")
        // Chunk starts 0.25 s before speech onset at 2 s; segment is 0.25 s into the chunk.
        #expect(abs(segment.start - 2.0) < 0.1)
        #expect(abs(segment.end - 2.95) < 0.1)
    }

    @Test func missingModelReportsStatusAndNeverTranscribes() async {
        let recorder = Recorder()
        let backend = ParakeetLiveBackend(isModelReady: { _ in false }, transcribe: { url, variant in
            recorder.call(url, variant)
            return TranscriptionResult(text: "unexpected")
        })
        await ParakeetLiveChannel.run(Self.request(Self.audio(silence: 0, speech: 1, trailing: 1.2), recorder),
                                      variant: "v3", chunkSeconds: 6, backend: backend)
        #expect(recorder.calls.isEmpty)
        #expect(recorder.segments.isEmpty)
        #expect(recorder.statuses.contains { $0.contains("Settings") })
    }

    @Test func repeatedFailuresPauseTheChannelInsteadOfRetryingEveryChunk() async {
        struct Boom: Error {}
        let recorder = Recorder()
        let backend = ParakeetLiveBackend(isModelReady: { _ in true }, transcribe: { url, variant in
            recorder.call(url, variant)
            throw Boom()
        })
        // Five separate utterances → five chunks; only the first three are attempted.
        let parts = (0..<5).map { _ in Self.audio(silence: 0.3, speech: 0.6, trailing: 1.2) }
        let combined = AsyncStream<LiveAudioBuffer> { continuation in
            Task {
                for part in parts { for await buffer in part { continuation.yield(buffer) } }
                continuation.finish()
            }
        }
        await ParakeetLiveChannel.run(Self.request(combined, recorder), variant: "v3", chunkSeconds: 6, backend: backend)
        #expect(recorder.calls.count == ParakeetLiveChannel.maxConsecutiveFailures)
        #expect(recorder.statuses.contains { $0.hasPrefix("Live transcript paused") })
    }

    @Test func textWithoutTimingsSpansTheWholeChunk() {
        let segments = ParakeetLiveChannel.liveSegments(from: TranscriptionResult(text: " goedemorgen "),
                                                        offset: 10, duration: 4, speaker: "Participant")
        #expect(segments.count == 1)
        #expect(segments.first?.start == 10)
        #expect(segments.first?.end == 14)
        #expect(segments.first?.text == "goedemorgen")
        #expect(segments.first?.speaker == "Participant")
    }

    @Test func blankSegmentsAreDropped() {
        let result = TranscriptionResult(text: "ja", segments: [.init(start: 0, end: 1, text: "  "), .init(start: 1, end: 2, text: "ja")])
        let segments = ParakeetLiveChannel.liveSegments(from: result, offset: 5, duration: 3, speaker: "You")
        #expect(segments.map(\.text) == ["ja"])
        #expect(segments.first?.start == 6)
    }
}
