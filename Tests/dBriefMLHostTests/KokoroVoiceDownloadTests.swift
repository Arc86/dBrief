import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

@Suite("Kokoro voice downloads")
struct KokoroVoiceDownloadTests {
    @Test func rejectsInvalidDownloadWithoutCachingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await KokoroVoiceDownload.ensure(.afBella, repoDirectory: directory) { url in
                #expect(url.lastPathComponent == "af_bella.bin")
                return Data(repeating: 0, count: 522_240)
            }
            Issue.record("Invalid voice data was accepted")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("af_bella.bin").path))
        }
    }
}

// Opt-in smoke test: requires cached CoreML models and verified voice fixtures.
// KOKORO_VOICE_FIXTURES points at a directory of the published English .bin packs.
@Suite("Kokoro English voice synthesis", .enabled(if: ProcessInfo.processInfo.environment["KOKORO_VOICE_FIXTURES"] != nil))
struct KokoroEnglishSynthesisTests {
    @Test func allEnglishVoicesSynthesizeAndReuseCachedPacks() async throws {
        let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KOKORO_VOICE_FIXTURES"]!)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let service = KokoroTTSService { _ in }
        for voice in KokoroVoice.allCases {
            let data = try Data(contentsOf: fixtures.appendingPathComponent("\(voice.rawValue).bin"))
            try await KokoroVoiceDownload.ensure(voice, repoDirectory: temporary) { _ in data }
            try await KokoroVoiceDownload.ensure(voice, repoDirectory: temporary) { _ in
                Issue.record("Cached voice was downloaded again")
                throw URLError(.notConnectedToInternet)
            }
            // A corrupt cached file must be repaired on the next attempt.
            let target = temporary.appendingPathComponent("\(voice.rawValue).bin")
            try Data("broken".utf8).write(to: target)
            try await KokoroVoiceDownload.ensure(voice, repoDirectory: temporary) { _ in data }
            #expect(try Data(contentsOf: target) == data)

            let result = try await service.synthesize(
                text: "Here's a quick preview of how your spoken summary will sound.",
                outputPath: temporary.appendingPathComponent("\(voice.rawValue).wav").path,
                voice: voice.rawValue, language: nil, instruction: nil, model: nil)
            #expect(result.durationSeconds > 1)
            #expect(result.sampleRate == 24_000)
            #expect(try Data(contentsOf: URL(fileURLWithPath: result.outputPath)).count > 48_000)
            print("Synthesized \(voice.rawValue): \(result.durationSeconds)s")
        }
        await service.unload()
    }
}
