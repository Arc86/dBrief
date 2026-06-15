import AVFoundation
import Foundation
import Speech
import dBriefWire
import os

private let log = Logger.localTranscription

/// Real-time, in-process transcription during recording using Apple's Speech
/// framework. Runs two independent recognition channels — the local microphone
/// (speaker "You") and the system/remote audio (speaker "Participant") — fed by
/// live `AVAudioPCMBuffer` streams tapped from `AudioCaptureManager`.
///
/// On macOS 26+ each channel uses the modern `SpeechAnalyzer`/`SpeechTranscriber`
/// streaming API (volatile + finalized results). On macOS 14–25 it falls back to
/// `SFSpeechAudioBufferRecognitionRequest`. This is a *preview*: the authoritative
/// high-quality transcript is still produced post-recording from the merged CAF.
actor LiveTranscriptionService {
    /// Speaker labels used for the two live channels.
    enum Channel: String {
        case mic = "You"
        case system = "Participant"
    }

    private var channelTasks: [Task<Void, Never>] = []

    /// Starts live transcription on the supplied channels. Pass `nil` for a channel
    /// that has no audio source (e.g. no screen-recording permission → no system audio).
    /// - Parameters:
    ///   - onFinalized: finalized segments (already speaker-tagged) to append to the timeline.
    ///   - onVolatile: the current in-progress hypothesis for a channel ("" clears it).
    ///   - onStatus: human-readable progress ("Preparing language…").
    func start(
        mic: AsyncStream<LiveAudioBuffer>?,
        system: AsyncStream<LiveAudioBuffer>?,
        language: String,
        onFinalized: @escaping @Sendable ([LiveTranscriptSegment]) -> Void,
        onVolatile: @escaping @Sendable (String, String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        if let mic {
            channelTasks.append(Task {
                await Self.runChannel(audio: mic, channel: .mic, language: language,
                                      onFinalized: onFinalized, onVolatile: onVolatile, onStatus: onStatus)
            })
        }
        if let system {
            channelTasks.append(Task {
                await Self.runChannel(audio: system, channel: .system, language: language,
                                      onFinalized: onFinalized, onVolatile: onVolatile, onStatus: onStatus)
            })
        }
    }

    func stop() {
        for task in channelTasks { task.cancel() }
        channelTasks = []
    }

    // MARK: - Channel dispatch

    private static func runChannel(
        audio: AsyncStream<LiveAudioBuffer>,
        channel: Channel,
        language: String,
        onFinalized: @escaping @Sendable ([LiveTranscriptSegment]) -> Void,
        onVolatile: @escaping @Sendable (String, String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async {
        if #available(macOS 26, *) {
            do {
                try await runModernChannel(audio: audio, channel: channel, language: language,
                                           onFinalized: onFinalized, onVolatile: onVolatile, onStatus: onStatus)
                return
            } catch {
                log.error("Live \(channel.rawValue, privacy: .public) modern channel failed: \(error.localizedDescription, privacy: .public)")
                onVolatile(channel.rawValue, "")
                return
            }
        }
        await runLegacyChannel(audio: audio, channel: channel, language: language,
                               onFinalized: onFinalized, onVolatile: onVolatile)
    }

    // MARK: - Modern (macOS 26+) SpeechAnalyzer streaming

    @available(macOS 26, *)
    private static func runModernChannel(
        audio: AsyncStream<LiveAudioBuffer>,
        channel: Channel,
        language: String,
        onFinalized: @escaping @Sendable ([LiveTranscriptSegment]) -> Void,
        onVolatile: @escaping @Sendable (String, String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        let requestedLocale: Locale = language.isEmpty ? .current : Locale(identifier: language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleSpeechAnalyzerError.localeNotSupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("Preparing language…")
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        // Consume results concurrently with feeding input.
        let resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let speaker = channel.rawValue
                    if result.isFinal {
                        let chunk = chunk(from: result)
                        let segments = AppleSpeechResultMapper.liveSegments(from: [chunk], speaker: speaker)
                        if !segments.isEmpty { onFinalized(segments) }
                        onVolatile(speaker, "")
                    } else {
                        onVolatile(speaker, String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            } catch {
                log.error("Live \(channel.rawValue, privacy: .public) results stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        try await analyzer.start(inputSequence: inputSequence)

        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        for await wrapped in audio {
            if Task.isCancelled { break }
            let buffer = wrapped.buffer
            let converted = analyzerFormat.flatMap { fmt -> AVAudioPCMBuffer? in
                // Rebuild the converter when the source format changes — a mid-recording
                // mic hot-swap (`switchMicrophoneDevice`) can change sample rate/channels,
                // and a stale converter would garble or drop the live audio.
                if converter == nil || converterInputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: fmt)
                    converterInputFormat = buffer.format
                }
                return converter.flatMap { convert(buffer, to: fmt, using: $0) }
            } ?? buffer
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }

        inputBuilder.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        // Drain (don't cancel) the results task: `finalizeAndFinishThroughEndOfInput`
        // ends `transcriber.results`, so awaiting the task lets the last finalized
        // segment(s) be delivered instead of being dropped by an early cancel.
        await resultsTask.value
        onVolatile(channel.rawValue, "")
    }

    @available(macOS 26, *)
    private static func chunk(from result: SpeechTranscriber.Result) -> AppleSpeechChunk {
        let attributed = result.text
        var runs: [AppleSpeechRun] = []
        for run in attributed.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            runs.append(AppleSpeechRun(
                text: String(attributed[run.range].characters),
                start: timeRange.start.seconds,
                end: timeRange.end.seconds
            ))
        }
        return AppleSpeechChunk(
            text: String(attributed.characters),
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            runs: runs
        )
    }

    @available(macOS 26, *)
    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            log.error("Live audio convert error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    // MARK: - Legacy (macOS 14–25) SFSpeechRecognizer streaming

    private static func runLegacyChannel(
        audio: AsyncStream<LiveAudioBuffer>,
        channel: Channel,
        language: String,
        onFinalized: @escaping @Sendable ([LiveTranscriptSegment]) -> Void,
        onVolatile: @escaping @Sendable (String, String) -> Void
    ) async {
        let locale: Locale = language.isEmpty ? .current : Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            log.warning("Live \(channel.rawValue, privacy: .public): SFSpeechRecognizer unavailable")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let speaker = channel.rawValue
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                if result.isFinal {
                    let segs = result.bestTranscription.segments.map { seg in
                        LiveTranscriptSegment(start: seg.timestamp, end: seg.timestamp + seg.duration,
                                              text: seg.substring, speaker: speaker)
                    }
                    if !segs.isEmpty { onFinalized(segs) }
                    onVolatile(speaker, "")
                } else {
                    onVolatile(speaker, result.bestTranscription.formattedString)
                }
            }
            if let error {
                log.error("Live \(channel.rawValue, privacy: .public) legacy task ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        for await wrapped in audio {
            if Task.isCancelled { break }
            request.append(wrapped.buffer)
        }
        request.endAudio()
        task.finish()
        onVolatile(speaker, "")
    }
}
