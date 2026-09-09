import AVFoundation
import Foundation
import Testing
@testable import dBrief

@Suite("Audio converter retirement")
struct AudioConversionDrainTests {
    @Test("A failed drain keeps recovered audio and reports a track write failure")
    func partialDrainFailure() throws {
        enum Failure: Error { case drain }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-partial-drain-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        let tail = LiveAudioBuffer(try buffer(rate: 16_000, frames: 160))
        let sink = MicCaptureSink(writer: writer, drain: { emit in
            emit(tail.buffer)
            throw Failure.drain
        })
        sink.finish()
        sink.finish()
        writer.close()
        #expect(try AVAudioFile(forReading: url).length == 160)
        #expect(writer.diagnostics.framesWritten == 160)
        #expect(writer.diagnostics.writeErrors == 1)
    }

    @Test("Finishing a converter recovers the tail once", arguments: [44_100.0, 48_000.0])
    func finishConverter(rate: Double) throws {
        let input = try buffer(rate: rate, frames: Int(rate / 10))
        let target = try format(16_000)
        let converter = try #require(MicFormatConverter(from: input.format, to: target))
        var frames = 0
        for _ in 0..<10 { frames += Int(try #require(converter.convert(input)).frameLength) }
        let tail = try converter.finish()
        frames += tail.reduce(0) { $0 + Int($1.frameLength) }
        #expect(frames == 16_000)
        #expect(try converter.finish().isEmpty)
        #expect(converter.convert(input) == nil)
    }

    @Test("Unused converters finish without inventing audio")
    func unusedConverter() throws {
        let converter = try #require(MicFormatConverter(from: format(48_000), to: format(16_000)))
        #expect(try converter.finish().isEmpty)
        #expect(try converter.finish().isEmpty)
    }

    @Test("Upsampling drains tails larger than one output buffer")
    func largeUpsamplingTail() throws {
        let input = try buffer(rate: 8000, frames: 8000)
        let converter = try #require(MicFormatConverter(from: input.format, to: format(48_000)))
        let first = try #require(converter.convert(input))
        let tail = try converter.finish()
        #expect(tail.count > 1)
        #expect(Int(first.frameLength) + tail.reduce(0) { $0 + Int($1.frameLength) } == 48_000)
    }

    @Test("Retired mic taps drain to disk and live preview, then reject late callbacks")
    func retireMicSink() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-drain-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        try writer.write(buffer(rate: 16_000, frames: 160))
        let (stream, continuation) = AsyncStream<LiveAudioBuffer>.makeStream()
        let input = try buffer(rate: 48_000, frames: 4800)
        let converter = try #require(MicFormatConverter(from: input.format, to: format(16_000)))
        let sink = MicCaptureSink(writer: writer, converter: converter, liveSink: continuation)
        for _ in 0..<10 { sink.receive(input) }
        sink.finish()
        sink.finish()
        writer.close()
        // AudioTrackWriter permits reopening after close. A retired sink must
        // prevent a late callback from reopening and truncating this same file.
        sink.receive(input)
        continuation.finish()
        var liveFrames = 0
        for await item in stream { liveFrames += Int(item.buffer.frameLength) }
        #expect(liveFrames == 16_000)
        #expect(writer.diagnostics.framesWritten == 16_160)
        #expect(writer.diagnostics.droppedBuffers == 0)
        #expect(try AVAudioFile(forReading: url).length == 16_160)
    }

    @Test("Replacing a live source format drains the old converter before new audio")
    func replaceLiveFormat() throws {
        let conversion = LiveAudioConversion(targetFormat: try format(16_000))
        var output: [AVAudioPCMBuffer] = []
        for _ in 0..<10 { output += try conversion.convert(buffer(rate: 48_000, frames: 4800, value: 0.25)) }
        for _ in 0..<10 { output += try conversion.convert(buffer(rate: 44_100, frames: 4410, value: -0.25)) }
        output += try conversion.finish()
        let samples = output.flatMap { Array(UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength))) }
        #expect(samples.count == 32_000)
        #expect(samples[15_000] > 0.24)
        #expect(samples[17_000] < -0.24)
        #expect(output.allSatisfy { $0.format.sampleRate == 16_000 })
        #expect(try conversion.finish().isEmpty)
        #expect(throws: (any Error).self) { try conversion.convert(buffer(rate: 48_000, frames: 4800)) }
    }

    private func format(_ rate: Double) throws -> AVAudioFormat {
        try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    }

    private func buffer(rate: Double, frames: Int, value: Float = 0.25) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format(rate), frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { buffer.floatChannelData![0][index] = value }
        return buffer
    }
}
