import Testing
@testable import dBrief
import AVFoundation

@Suite("AudioFileWriter")
struct AudioFileWriterTests {
    @Test("init does not create file before first write")
    func initDoesNotCreateFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
        let writer = AudioFileWriter(fileURL: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = writer
    }

    @Test("write creates file at buffer's sample rate")
    func writeLazily() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
        let writer = AudioFileWriter(fileURL: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        try writer.write(buffer)
        #expect(FileManager.default.fileExists(atPath: writer.actualFileURL.path))
        try? FileManager.default.removeItem(at: writer.actualFileURL)
    }
}
