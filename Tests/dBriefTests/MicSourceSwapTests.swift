import AVFoundation
import Foundation
import Testing
@testable import dBrief

/// A device switch replaces the mic source mid-recording. The new source's
/// format is only known from its first buffer, and the outage between sources
/// must stay on the mic track's timeline so it remains in sync with system audio.
@Suite("Mic source swap")
struct MicSourceSwapTests {
    @Test("A new source at a different rate converts into the established track")
    func adaptiveConversion() throws {
        let (writer, url) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        try writer.write(buffer(rate: 16_000, frames: 1_600))
        let sink = MicCaptureSink(writer: writer)
        for _ in 0..<10 { sink.receive(try buffer(rate: 48_000, frames: 4_800)) }
        sink.finish()
        writer.close()
        #expect(writer.diagnostics.droppedBuffers == 0)
        #expect(try AVAudioFile(forReading: url).length == 1_600 + 16_000)
    }

    @Test("A converted source keeps its signal, not just its length")
    func adaptiveConversionKeepsSignal() throws {
        let (writer, url) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        try writer.write(buffer(rate: 16_000, frames: 1_600, value: 0))
        let sink = MicCaptureSink(writer: writer)
        for _ in 0..<10 { sink.receive(try buffer(rate: 48_000, frames: 4_800, value: 0.25)) }
        sink.finish()
        writer.close()
        let samples = try readSamples(url)
        #expect(samples[1_600 + 8_000] > 0.2)
    }

    @Test("The first source establishes the track without conversion")
    func firstSourceEstablishesFormat() throws {
        let (writer, url) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = MicCaptureSink(writer: writer)
        for _ in 0..<3 { sink.receive(try buffer(rate: 48_000, frames: 4_800)) }
        sink.finish()
        writer.close()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.length == 14_400)
    }

    @Test("The outage between two sources is kept as silence")
    func gapBetweenSourcesIsPadded() throws {
        let (writer, url) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let timeline = MicTimeline()
        let start: UInt64 = 1_000_000_000

        let old = MicCaptureSink(writer: writer, timeline: timeline)
        old.receive(try buffer(rate: 16_000, frames: 1_600), hostTime: start)          // 0.0–0.1 s
        old.finish()

        let new = MicCaptureSink(writer: writer, timeline: timeline)
        new.receive(try buffer(rate: 16_000, frames: 1_600), hostTime: start + hostTicks(0.6)) // 0.6–0.7 s
        new.finish()
        writer.close()

        let samples = try readSamples(url)
        #expect(samples.count == 1_600 + 8_000 + 1_600)
        #expect(samples[1_000] > 0.2)
        #expect(samples[5_000] == 0)
        #expect(samples[10_000] > 0.2)
    }

    @Test("A pause is not padded: both tracks stop together")
    func pauseResetsTheTimeline() throws {
        let (writer, url) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let timeline = MicTimeline()
        let start: UInt64 = 1_000_000_000
        let old = MicCaptureSink(writer: writer, timeline: timeline)
        old.receive(try buffer(rate: 16_000, frames: 1_600), hostTime: start)
        old.finish()
        timeline.reset()
        let new = MicCaptureSink(writer: writer, timeline: timeline)
        new.receive(try buffer(rate: 16_000, frames: 1_600), hostTime: start + hostTicks(5))
        new.finish()
        writer.close()
        #expect(try AVAudioFile(forReading: url).length == 3_200)
    }

    @Test("Jitter within one source and tiny handover gaps are not padded")
    func smallGapsAreIgnored() throws {
        let (writer, url) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let timeline = MicTimeline()
        let start: UInt64 = 1_000_000_000
        let old = MicCaptureSink(writer: writer, timeline: timeline)
        old.receive(try buffer(rate: 16_000, frames: 1_600), hostTime: start)
        old.receive(try buffer(rate: 16_000, frames: 1_600), hostTime: start + hostTicks(0.3))
        old.finish()
        let new = MicCaptureSink(writer: writer, timeline: timeline)
        new.receive(try buffer(rate: 16_000, frames: 1_600), hostTime: start + hostTicks(0.42))
        new.finish()
        writer.close()
        #expect(try AVAudioFile(forReading: url).length == 4_800)
    }

    @Test("The gap is padded in the established format when the new source converts")
    func gapPaddedAcrossRates() throws {
        let (writer, url) = makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let timeline = MicTimeline()
        let start: UInt64 = 1_000_000_000
        let old = MicCaptureSink(writer: writer, timeline: timeline)
        old.receive(try buffer(rate: 16_000, frames: 1_600), hostTime: start)            // ends 0.1 s
        old.finish()
        let new = MicCaptureSink(writer: writer, timeline: timeline)
        for index in 0..<10 {                                                            // 1.1–2.1 s @48k
            new.receive(try buffer(rate: 48_000, frames: 4_800),
                        hostTime: start + hostTicks(1.1 + Double(index) * 0.1))
        }
        new.finish()
        writer.close()
        #expect(try AVAudioFile(forReading: url).length == 1_600 + 16_000 + 16_000)
    }

    // MARK: Helpers

    private func makeWriter() -> (AudioTrackWriter, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-swap-\(UUID()).caf")
        return (AudioTrackWriter(url: url, role: .mic), url)
    }

    private func hostTicks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }

    private func buffer(rate: Double, frames: Int, value: Float = 0.25) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { buffer.floatChannelData![0][index] = value }
        return buffer
    }

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
