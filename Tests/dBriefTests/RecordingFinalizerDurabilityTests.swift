import AVFoundation
import Foundation
import Testing
@testable import dBrief

@Suite("Recording finalizer durability")
struct RecordingFinalizerDurabilityTests {
    @Test("A mic CAF with nine unlabeled channels finalizes to mono AAC")
    @MainActor
    func unlabeledMultichannelMicFinalizes() async throws {
        guard let ffmpeg = FFmpegLocator.resolve() else { return }

        let files = FileManager.default
        let root = files.temporaryDirectory
            .appendingPathComponent("dbrief-multichannel-finalizer-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        // FFmpeg can generate a labeled nine-channel source. AVAudioFile writes
        // the same samples as an unlabeled CAF, matching the captured mic file.
        let generated = root.appendingPathComponent("source.caf")
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: ffmpeg)
        let ffmpegArguments = [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.1",
            "-filter_complex",
            "[0:a]asplit=9[a0][a1][a2][a3][a4][a5][a6][a7][a8];"
                + "[a0][a1][a2][a3][a4][a5][a6][a7][a8]amerge=inputs=9[out]",
            "-map", "[out]", "-c:a", "pcm_f32le", "-f", "caf", "-y", generated.path,
        ]
        generator.arguments = ffmpeg == "/usr/bin/env" ? ["ffmpeg"] + ffmpegArguments : ffmpegArguments
        generator.standardOutput = Pipe()
        generator.standardError = Pipe()
        try generator.run()
        generator.waitUntilExit()
        #expect(generator.terminationStatus == 0)

        let source = try AVAudioFile(forReading: generated)
        let format = source.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        try source.read(into: buffer)
        let mic = root.appendingPathComponent("capture.mic.caf")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: mic, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 9,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        try writer?.write(from: buffer)
        writer = nil

        let recording = Recording(date: Date(), fileURL: mic, meetingTitleDraft: "Multichannel mic")
        recording.duration = 0.1
        let result = try await RecordingFinalizer().finalize(
            tracks: CapturedTracks(systemURL: nil, micURL: mic),
            snapshot: RecordingFinalizationSnapshot(recording: recording),
            baseFolder: root.appendingPathComponent("Recordings"),
            segmentationEnabled: false
        )

        #expect(files.fileExists(atPath: result.masterAudioURL.path))
        #expect(result.ffmpegDiagnostics?.exitStatus == 0)
        #expect(result.playbackMapping == .encodedAAC(.init(systemURL: nil, micURL: mic)))
        let metadata = try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: result.metadataURL))
        #expect(metadata.playbackMapping == result.playbackMapping)
        #expect(!files.fileExists(atPath: mic.path))
    }

    @Test
    func fallbackSkipsHeaderOnlyMicCopiesSystemAndPreservesRawTracks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-finalizer-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mic = root.appendingPathComponent("mic.caf")
        let system = root.appendingPathComponent("system.caf")
        let target = root.appendingPathComponent("master.m4a")
        try Data(repeating: 1, count: 128).write(to: mic)
        let expected = Data(repeating: 2, count: 5_000)
        try expected.write(to: system)

        try await RecordingFinalizer().fallbackPromoteTrack(
            tracks: CapturedTracks(systemURL: system, micURL: mic),
            targetURL: target
        )

        #expect(try Data(contentsOf: target) == expected)
        #expect(FileManager.default.fileExists(atPath: mic.path))
        #expect(FileManager.default.fileExists(atPath: system.path))
    }
}
