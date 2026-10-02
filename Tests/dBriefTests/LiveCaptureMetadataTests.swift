import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import dBrief

@Suite struct LiveCaptureMetadataTests {
    private func buffer(rate: Double = 16000, frames: UInt32 = 100) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let value = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        value.frameLength = frames
        for i in 0..<Int(frames) { value.floatChannelData![0][i] = 0.25 }
        return value
    }

    @Test func directMicRetainsStampAndIndependentEmissionAndFileRanges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-stamps-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        try writer.write(buffer(frames: 50))
        let (stream, continuation) = AsyncStream<LiveAudioBuffer>.makeStream()
        let sink = MicCaptureSink(writer: writer, liveSink: continuation)
        let input = try buffer()
        sink.receive(input, time: AVAudioTime(sampleTime: 800, atRate: 16000))
        sink.receive(try buffer(rate: 48000), time: AVAudioTime(hostTime: 42))
        sink.finish()
        writer.close()
        sink.receive(input)
        continuation.finish()
        // Borrowed tap storage can now change without changing the live copy.
        input.floatChannelData![0][0] = -1
        var items: [LiveAudioBuffer] = []
        for await item in stream { items.append(item) }
        #expect(items.count == 2)
        let first = try #require(items.first?.metadata), second = try #require(items.last?.metadata)
        #expect(items[0].buffer.floatChannelData![0][0] == 0.25)
        #expect(first.role == .mic && first.sourceEpoch == second.sourceEpoch)
        #expect(first.timestamp == .microphone(hostTime: nil, sampleTime: 800, sampleRate: 16000))
        #expect(first.emittedFrames == .init(startFrame: 0, frameCount: 100, sampleRate: 16000))
        #expect(first.writeOutcome == .receipt(.written(startFrame: 50, frameCount: 100, sampleRate: 16000)))
        #expect(second.timestamp == .microphone(hostTime: 42, sampleTime: nil, sampleRate: nil))
        #expect(second.writeOutcome == .receipt(.dropped(.formatMismatch)))
        #expect(first.converter == nil)
        #expect(try AVAudioFile(forReading: url).length == 150)
    }

    @Test func failedWriteStillEmitsPreviewWithExplicitFailure() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing/file.caf")
        let writer = AudioTrackWriter(url: url, role: .mic)
        let (stream, continuation) = AsyncStream<LiveAudioBuffer>.makeStream()
        let sink = MicCaptureSink(writer: writer, liveSink: continuation)
        sink.receive(try buffer())
        sink.finish()
        continuation.finish()
        var values: [LiveAudioBuffer] = []
        for await item in stream { values.append(item) }
        #expect(values.count == 1)
        #expect(try #require(values.first?.metadata).writeOutcome == .failed)
        #expect(writer.diagnostics.framesWritten == 0)
    }

    @Test func converterTailsKeepInputContextWithoutInventingOutputTimestamps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("converter-stamps-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        let (stream, continuation) = AsyncStream<LiveAudioBuffer>.makeStream()
        let input = try buffer(rate: 48000, frames: 4800)
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let converter = try #require(MicFormatConverter(from: input.format, to: target))
        let sink = MicCaptureSink(writer: writer, converter: converter, liveSink: continuation)
        sink.receive(input, time: AVAudioTime(hostTime: 10))
        sink.receive(input, time: AVAudioTime(hostTime: 20))
        sink.finish()
        sink.finish()
        writer.close()
        continuation.finish()
        var nextFrame: Int64 = 0, contexts: [LiveAudioConverterContext] = [], epochs = Set<UUID>()
        for await item in stream {
            let meta = try #require(item.metadata), context = try #require(meta.converter)
            let count = Int64(item.buffer.frameLength)
            #expect(meta.timestamp == .unavailable)
            #expect(meta.emittedFrames == .init(startFrame: nextFrame, frameCount: count, sampleRate: 16000))
            #expect(meta.writeOutcome == .receipt(.written(startFrame: nextFrame, frameCount: count, sampleRate: 16000)))
            #expect(!context.alignmentVerified)
            #expect(context.firstInputTimestamp == .microphone(hostTime: 10, sampleTime: nil, sampleRate: nil))
            contexts.append(context)
            epochs.insert(meta.sourceEpoch)
            nextFrame += count
        }
        #expect(nextFrame == 3200 && epochs.count == 1)
        let tail = try #require(contexts.last)
        #expect(tail.isDrain)
        #expect(tail.latestInputTimestamp == .microphone(hostTime: 20, sampleTime: nil, sampleRate: nil))
        #expect(tail.admittedInputFrameCount == 9600 && tail.inputSampleRate == 48000)
        #expect(try AVAudioFile(forReading: url).length == nextFrame)
    }

    @Test func aReplacementTapHasANewSourceEpochWhileTheTrackContinues() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("epochs-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        let (stream, continuation) = AsyncStream<LiveAudioBuffer>.makeStream()
        for _ in 0..<2 {
            let sink = MicCaptureSink(writer: writer, liveSink: continuation)
            sink.receive(try buffer())
            sink.finish()
        }
        writer.close()
        continuation.finish()
        var values: [LiveAudioMetadata] = []
        for await item in stream { values.append(try #require(item.metadata)) }
        #expect(values.count == 2 && values[0].sourceEpoch != values[1].sourceEpoch)
        #expect(values[1].emittedFrames?.startFrame == 0)
        #expect(values[1].writeOutcome == .receipt(.written(startFrame: 100, frameCount: 100, sampleRate: 16000)))
    }

    @Test func systemBuffersRetainRawPTSAndIndependentRestartEpochs() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-stamps-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .system)
        let (stream, continuation) = AsyncStream<LiveAudioBuffer>.makeStream()
        let sink = SystemCaptureSink(writer: writer, liveSink: continuation)
        sink.receive(try buffer(), presentationTime: CMTime(value: 123, timescale: 1000, flags: .valid, epoch: 7))
        sink.receive(try buffer(), presentationTime: .invalid)
        SystemCaptureSink(writer: writer, liveSink: continuation).receive(try buffer(), presentationTime: CMTime(value: 3, timescale: 1))
        writer.close()
        continuation.finish()
        var values: [LiveAudioMetadata] = []
        for await item in stream { values.append(try #require(item.metadata)) }
        #expect(values.count == 3)
        #expect(values[0].role == .system && values[0].converter == nil)
        #expect(values[0].timestamp == .systemPTS(value: 123, timescale: 1000, epoch: 7))
        #expect(values[1].timestamp == .unavailable)
        #expect(values[0].sourceEpoch == values[1].sourceEpoch && values[1].sourceEpoch != values[2].sourceEpoch)
        #expect(values[1].emittedFrames == .init(startFrame: 100, frameCount: 100, sampleRate: 16000))
        #expect(values[2].emittedFrames?.startFrame == 0)
        #expect(values[2].writeOutcome == .receipt(.written(startFrame: 200, frameCount: 100, sampleRate: 16000)))
    }
}
