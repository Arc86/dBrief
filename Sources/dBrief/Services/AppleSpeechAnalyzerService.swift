import AVFoundation
import CoreMedia
import Foundation
import Speech
import dBriefWire
import os

private let log = Logger.localTranscription

/// On-device transcription using Apple's macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`.
///
/// This is the modern replacement for `SFSpeechRecognizer` (`LocalTranscriptionService`):
/// better long-form accuracy, native audio-file loading via `AVAudioFile`, and per-run
/// `audioTimeRange` attributes that give us word-level timestamps. The `.appleSpeech`
/// engine routes here on macOS 26+ and falls back to `LocalTranscriptionService` on older
/// systems or unsupported locales (see `RecordingManager`).
@available(macOS 26, *)
actor AppleSpeechAnalyzerService {
    /// Whether `SpeechTranscriber` can transcribe `locale` (asset may still need download).
    static func supports(locale: Locale) async -> Bool {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    /// - Parameter status: human-readable progress updates ("Preparing language…", "Transcribing…").
    func transcribe(
        fileURL: URL,
        language: String,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> TranscriptionResult {
        let requestedLocale: Locale = language.isEmpty ? .current : Locale(identifier: language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleSpeechAnalyzerError.localeNotSupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Download the language asset on first use for this locale.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Preparing language…")
            log.info("Downloading SpeechAnalyzer asset for \(locale.identifier(.bcp47), privacy: .public)")
            do {
                try await request.downloadAndInstall()
            } catch {
                throw AppleSpeechAnalyzerError.assetInstallFailed(error.localizedDescription)
            }
        }

        let preparedURL = try OggOpusConverter.preparedURL(for: fileURL)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: preparedURL)
        } catch {
            throw AppleSpeechAnalyzerError.audioLoadFailed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Start consuming results before feeding input so nothing is dropped.
        let collector = Task { () throws -> [AppleSpeechChunk] in
            var chunks: [AppleSpeechChunk] = []
            for try await result in transcriber.results {
                chunks.append(Self.chunk(from: result))
            }
            return chunks
        }

        status("Transcribing…")
        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }

        let chunks = try await collector.value
        let result = AppleSpeechResultMapper.map(chunks, language: language)
        log.info("SpeechAnalyzer transcription complete: \(result.text.prefix(80), privacy: .public)...")
        return result
    }

    /// Converts one finalized `SpeechTranscriber.Result` into a plain, testable chunk by
    /// reading each attributed-text run's `audioTimeRange` for word-level timing.
    private static func chunk(from result: SpeechTranscriber.Result) -> AppleSpeechChunk {
        let attributed = result.text
        var runs: [AppleSpeechRun] = []
        for run in attributed.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let runText = String(attributed[run.range].characters)
            runs.append(
                AppleSpeechRun(
                    text: runText,
                    start: timeRange.start.seconds,
                    end: timeRange.end.seconds
                )
            )
        }
        return AppleSpeechChunk(
            text: String(attributed.characters),
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            runs: runs
        )
    }
}

@available(macOS 26, *)
enum AppleSpeechAnalyzerError: Error, LocalizedError {
    case localeNotSupported
    case assetInstallFailed(String)
    case audioLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .localeNotSupported:
            "Apple Speech (macOS 26) does not support this language."
        case .assetInstallFailed(let message):
            "Failed to download the speech language model. \(message)"
        case .audioLoadFailed(let message):
            "Could not read the audio for transcription. \(message)"
        }
    }
}
