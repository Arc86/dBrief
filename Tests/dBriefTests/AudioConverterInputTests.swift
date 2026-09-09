import AVFoundation
import Foundation
import Testing
@testable import dBrief

@Suite("Streaming PCM conversion")
struct AudioConverterInputTests {
    @Test("Concurrent input requests supply a chunk exactly once without ending the stream")
    func suppliesOnce() async throws {
        let buffer = try makeBuffer(rate: 16_000, frames: 160)
        let input = AudioConverterInput(buffer)
        let supplied = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    var status = AVAudioConverterInputStatus.endOfStream
                    let result = input.take(status: &status)
                    #expect(status == (result == nil ? .noDataNow : .haveData))
                    return result == nil ? 0 : 1
                }
            }
            var count = 0
            for await value in group { count += value }
            return count
        }
        #expect(supplied == 1)
    }

    @Test("Same-rate chunks preserve every sample across successive conversions")
    func preservesSamples() throws {
        let first = try makeBuffer(rate: 16_000, frames: 257)
        let converter = try #require(MicFormatConverter(from: first.format, to: first.format))
        for offset in [0, 257, 514] {
            let input = try makeBuffer(rate: 16_000, frames: 257, offset: offset)
            let output = try #require(converter.convert(input))
            #expect(output.frameLength == input.frameLength)
            let actual = try #require(output.floatChannelData)[0]
            let expected = try #require(input.floatChannelData)[0]
            for frame in 0..<Int(input.frameLength) {
                #expect(abs(actual[frame] - expected[frame]) < 0.000_001)
            }
        }
    }

    @Test("Resampling keeps a continuous tone with bounded streaming latency", arguments: [44_100.0, 48_000.0])
    func resamples(rate: Double) throws {
        let source = try makeBuffer(rate: rate, frames: Int(rate / 10))
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(MicFormatConverter(from: source.format, to: target))
        var samples: [Float] = []
        for chunk in 0..<10 {
            let input = try makeBuffer(rate: rate, frames: Int(rate / 10), offset: chunk * Int(rate / 10))
            let output = try #require(converter.convert(input))
            #expect(output.format == target)
            samples.append(contentsOf: UnsafeBufferPointer(start: try #require(output.floatChannelData)[0], count: Int(output.frameLength)))
        }
        // AVAudioConverter also buffers packet batches: .noDataNow can retain more
        // than the filter tail. Require less than one input chunk of latency here;
        // the drain test below checks that every retained frame is accounted for.
        #expect(samples.count > 14_400 && samples.count <= 16_000, "Converted \(samples.count) frames at \(rate) Hz")
        let settled = Array(samples.dropFirst(100).dropLast(100))
        let crossings = zip(settled, settled.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let frequency = Double(crossings) * 16_000 / Double(settled.count)
        #expect(abs(frequency - 440) < 3)
        let rms = sqrt(settled.reduce(0.0) { $0 + Double($1 * $1) } / Double(settled.count))
        #expect(abs(rms - 0.25 / sqrt(2)) < 0.01)
    }

    @Test("Draining resampled chunks accounts for every input frame", arguments: [44_100.0, 48_000.0])
    func drainsAllFrames(rate: Double) throws {
        let first = try makeBuffer(rate: rate, frames: Int(rate / 10))
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: first.format, to: target))
        var frameCount = 0
        for chunk in 0..<10 {
            let input = AudioConverterInput(try makeBuffer(rate: rate, frames: Int(rate / 10), offset: chunk * Int(rate / 10)))
            let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 2624))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                input.take(status: status)
            }
            #expect(error == nil)
            #expect(status != .error && status != .endOfStream)
            frameCount += Int(output.frameLength)
        }
        // End-of-stream is only appropriate when the source actually finishes,
        // never between the chunks supplied by AudioConverterInput.
        let tail = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_000))
        var error: NSError?
        let status = converter.convert(to: tail, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        #expect(error == nil)
        #expect(status != .error)
        #expect(frameCount + Int(tail.frameLength) == 16_000)
    }

    private func makeBuffer(rate: Double, frames: Int, offset: Int = 0) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try #require(buffer.floatChannelData)[0]
        for frame in 0..<frames {
            samples[frame] = Float(0.25 * sin(2 * Double.pi * 440 * Double(frame + offset) / rate))
        }
        return buffer
    }
}
