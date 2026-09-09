import AVFoundation
import Foundation
import Testing
@testable import dBrief

@Suite("Recording level display")
struct AudioLevelMeterTests {
    @Test func microphoneLevelsUseDecibelsRatherThanLinearAmplitude() {
        #expect(AudioLevelMeter.displayLevel(0) == 0)
        #expect(AudioLevelMeter.displayLevel(0.0001) == 0)
        #expect(abs(AudioLevelMeter.displayLevel(0.01) - 1.0 / 3) < 0.001)
        #expect(abs(AudioLevelMeter.displayLevel(0.1) - 2.0 / 3) < 0.001)
        #expect(AudioLevelMeter.displayLevel(1) == 1)
        #expect(AudioLevelMeter.displayLevel(2) == 1)
        #expect(AudioLevelMeter.displayLevel(.nan) == 0)
        #expect(AudioLevelMeter.displayLevel(.infinity) == 0)
    }

    @Test("Both stereo channels contribute to the meter", arguments: [false, true])
    func stereoPeak(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let channels = try #require(buffer.floatChannelData)
        if interleaved {
            for i in 0..<64 { channels[0][i] = 0 }
            channels[0][21] = -0.4
        } else {
            for channel in 0..<2 { for frame in 0..<32 { channels[channel][frame] = 0 } }
            channels[1][10] = -0.4
        }
        #expect(abs(AudioLevelMeter.peak(in: buffer) - 0.4) < 0.0001)
    }

    @Test func aBriefPeakSurvivesUntilTheNextDisplayTickWithoutChangingSavedAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meter-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        for i in 0..<64 { buffer.floatChannelData![0][i] = 0.2 }
        try writer.write(buffer)
        for i in 0..<64 { buffer.floatChannelData![0][i] = 0.001 }
        try writer.write(buffer)
        #expect(abs(writer.consumePeakLevel() - 0.2) < 0.0001)
        #expect(writer.consumePeakLevel() == 0)
        try writer.write(buffer)
        #expect(abs(writer.consumePeakLevel() - 0.001) < 0.0001)
        writer.close()
        let file = try AVAudioFile(forReading: url)
        let recorded = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 192))
        try file.read(into: recorded)
        #expect(recorded.frameLength == 192)
        #expect(abs(recorded.floatChannelData![0][0] - 0.2) < 0.0001)
        #expect(abs(recorded.floatChannelData![0][128] - 0.001) < 0.0001)
    }
}
