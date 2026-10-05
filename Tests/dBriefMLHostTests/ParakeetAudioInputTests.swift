import FluidAudio
import Foundation
import Testing
@testable import dBriefMLHost

/// The fixture is 2 s of 48 kHz AAC whose gapless (`iTunSMPB`) header claims
/// 4096 more frames than its packets decode to — the shape of real recordings
/// whose writer stamped jittery packet durations. `AVAudioFile.length` trusts
/// the header, so FluidAudio's disk-backed reader runs past the real end and
/// fails with `eofErr`; its in-memory resampler tolerates the overshoot.
@Suite("Parakeet audio input")
struct ParakeetAudioInputTests {
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    static let overstatedAAC = fixture("aac-overstated-length.m4a")
    static let trailingSilence = 16_000   // 1 s @ 16 kHz

    static func inMemorySamples() throws -> [Float] {
        guard case .samples(let samples) = try ParakeetTranscriptionService.prepareInput(fileURL: overstatedAAC) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return samples
    }

    /// Pins the upstream defect `prepareInput` works around. If this starts
    /// passing through, FluidAudio has fixed it and the PCM re-write is optional.
    @Test("FluidAudio's disk-backed reader fails on the original AAC")
    func fluidAudioRejectsOverstatedAAC() {
        #expect(throws: (any Error).self) {
            let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: Self.overstatedAAC, targetSampleRate: 16_000)
            source.cleanup()
        }
    }

    @Test("Short audio is transcribed in memory with trailing silence")
    func shortAudioStaysInMemory() throws {
        let samples = try Self.inMemorySamples()
        // ~2 s of decoded audio (the decoder's exact edge handling varies) + 1 s of silence.
        #expect(abs(samples.count - (32_000 + Self.trailingSilence)) < 1_000)
        #expect(samples.suffix(Self.trailingSilence).allSatisfy { $0 == 0 })
    }

    @Test("Long audio is handed to FluidAudio as an exact-length PCM file it can read")
    func longAudioUsesReadablePCMFile() throws {
        let input = try ParakeetTranscriptionService.prepareInput(
            fileURL: Self.overstatedAAC,
            maxInMemorySamples: 1_000
        )
        guard case .file(let url, let isTemporary) = input else {
            Issue.record("expected a file input, got \(input)")
            return
        }
        defer { if isTemporary { try? FileManager.default.removeItem(at: url) } }
        #expect(isTemporary)
        #expect(url != Self.overstatedAAC)

        // The exact reader FluidAudio's disk-backed transcription uses.
        let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: url, targetSampleRate: 16_000)
        defer { source.cleanup() }
        let expected = try Self.inMemorySamples()
        #expect(source.sampleCount == expected.count)
        var read = [Float](repeating: .nan, count: source.sampleCount)
        try read.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: 0, count: $0.count)
        }
        #expect(read == expected)
    }

    @Test("Undecodable audio falls back to FluidAudio's own file path")
    func undecodableAudioFallsBackToOriginalFile() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-not-audio-\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let input = try ParakeetTranscriptionService.prepareInput(fileURL: bogus)
        guard case .file(let url, let isTemporary) = input else {
            Issue.record("expected the original file, got \(input)")
            return
        }
        #expect(url == bogus)
        #expect(!isTemporary)
    }
}
