import Testing
@testable import dBrief
import AVFoundation

@Suite("AudioTrackWriter")
struct AudioTrackWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
    }

    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        return buf
    }

    @Test("init does not create file before first write")
    func initDoesNotCreateFile() {
        let url = tempURL()
        let writer = AudioTrackWriter(url: url, role: .mic)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = writer
    }

    @Test("first write creates file at the buffer's sample rate")
    func firstWriteCreatesFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        try writer.write(makeBuffer(sampleRate: 48000, channels: 1, frames: 512))
        writer.close()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test("format mismatch on later buffer is dropped, file stays intact")
    func formatMismatchDropped() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .system)
        try writer.write(makeBuffer(sampleRate: 48000, channels: 2, frames: 512))
        // Second buffer at wrong sample rate should be dropped, not crash.
        try writer.write(makeBuffer(sampleRate: 44100, channels: 2, frames: 512))
        writer.close()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48000)
        // Only the first buffer's frames are in the file.
        #expect(file.length == 512)
    }

    @Test("close is idempotent")
    func closeIdempotent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        try writer.write(makeBuffer(sampleRate: 48000, channels: 1, frames: 256))
        writer.close()
        writer.close()  // must not crash
    }

    @Test("peakLevel reflects the last buffer")
    func peakLevelUpdates() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        let buf = makeBuffer(sampleRate: 48000, channels: 1, frames: 256)
        buf.floatChannelData![0][100] = 0.5
        try writer.write(buf)
        #expect(writer.peakLevel == 0.5)
        writer.close()
    }

    @Test("write after close re-opens the file")
    func writeAfterClose() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        try writer.write(makeBuffer(sampleRate: 48000, channels: 1, frames: 256))
        writer.close()
        // Writing after close should not crash — it will re-open the file.
        try writer.write(makeBuffer(sampleRate: 48000, channels: 1, frames: 256))
        writer.close()
    }
}
