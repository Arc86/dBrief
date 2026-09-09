import AVFoundation
import Foundation
@preconcurrency import Speech
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
    enum Channel: String, Sendable {
        case mic = "You"
        case system = "Participant"
    }

    private var channelTasks: [Task<Void, Never>] = []
    private var hasStopped = false
    private var hasStarted = false
    private var stopTask: Task<Void, Never>?
    struct ChannelRequest: Sendable {
        let audio: AsyncStream<LiveAudioBuffer>
        let channel: Channel
        let language: String
        let onFinalized: @Sendable ([LiveTranscriptSegment]) -> Void
        let onVolatile: @Sendable (String, String) -> Void
        let onStatus: @Sendable (String) -> Void
    }
    private let run: @Sendable (ChannelRequest) async -> Void

    init(runChannel: @escaping @Sendable (ChannelRequest) async -> Void = { request in
        await LiveTranscriptionService.runChannel(audio: request.audio, channel: request.channel, language: request.language,
                              onFinalized: request.onFinalized, onVolatile: request.onVolatile, onStatus: request.onStatus)
    }) { self.run = runChannel }

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
        // A service belongs to one capture. Stop can reach this actor while the
        // caller is awaiting receipt preparation or the actor hop into start.
        guard !hasStopped, !hasStarted else { return }
        hasStarted = true
        let run = run
        for (channel, audio) in [(Channel.mic, mic), (.system, system)] {
            guard let audio else { continue }
            let request = ChannelRequest(audio: audio, channel: channel, language: language,
                onFinalized: onFinalized, onVolatile: onVolatile, onStatus: onStatus)
            channelTasks.append(Task { await run(request) })
        }
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        hasStopped = true
        let tasks = channelTasks
        tasks.forEach { $0.cancel() }
        let join = Task { for task in tasks { await task.value } }
        stopTask = join
        await join.value
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
        try Task.checkCancellation()
        let requestedLocale: Locale = language.isEmpty ? .current : Locale(identifier: language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleSpeechAnalyzerError.localeNotSupported
        }

        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try Task.checkCancellation()
            onStatus("Preparing language…")
            try await request.downloadAndInstall()
        }

        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        try Task.checkCancellation()
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        try await PrivacyTrace.perform(.init(stage: .liveTranscription, data: [.recordingAudio, .metadata],
                                             destination: .local(provider: .speechAnalyzer))) {
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
                    throw error
                }
            }

            let cancellation = LiveAnalyzerCancellation(cancel: {
                inputBuilder.finish()
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                _ = await resultsTask.result
            })
            try await cancellation.run {
                try await analyzer.start(inputSequence: inputSequence)
                try Task.checkCancellation()

                let conversion = analyzerFormat.map { LiveAudioConversion(targetFormat: $0) }
                for await wrapped in audio {
                    try Task.checkCancellation()
                    let buffers = try conversion?.convert(wrapped.buffer) ?? [wrapped.buffer]
                    for buffer in buffers { inputBuilder.yield(AnalyzerInput(buffer: buffer)) }
                }

                // Cancellation is terminal and prompt; only normal EOF drains.
                try Task.checkCancellation()
                for tail in try conversion?.finish() ?? [] {
                    inputBuilder.yield(AnalyzerInput(buffer: tail))
                }
                inputBuilder.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                // Drain (don't cancel) the results task: `finalizeAndFinishThroughEndOfInput`
                // ends `transcriber.results`, so awaiting the task lets the last finalized
                // segment(s) be delivered instead of being dropped by an early cancel.
                try await resultsTask.value
                try Task.checkCancellation()
                onVolatile(channel.rawValue, "")
            }
        }
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

        guard !Task.isCancelled else { return }
        let token = await PrivacyTrace.begin(.init(stage: .liveTranscription, data: [.recordingAudio, .metadata],
                                                   destination: .local(provider: .appleSpeech)))
        let completion = PrivacyTrace.Completion(token: token)
        guard !Task.isCancelled else {
            await completion.finish(.cancelled)
            return
        }
        let lifecycle = LiveRecognitionCompletion(completion: completion)
        let delegate = LiveSpeechRecognitionDelegate(lifecycle: lifecycle, speaker: channel.rawValue,
                                                    onFinalized: onFinalized, onVolatile: onVolatile)
        let task = recognizer.recognitionTask(with: request, delegate: delegate)
        lifecycle.installCancellation {
            request.endAudio()
            task.cancel()
        }
        // Feed and observe native completion independently. A recognizer error
        // must also stop an input consumer currently waiting for another buffer.
        let feed = Task {
            for await wrapped in audio {
                guard !Task.isCancelled else { break }
                request.append(wrapped.buffer)
            }
            if !Task.isCancelled {
                request.endAudio()
                task.finish()
            }
        }
        await withTaskCancellationHandler {
            await lifecycle.wait()
        } onCancel: {
            feed.cancel()
            lifecycle.requestCancellation()
        }
        feed.cancel()
        await feed.value
        // Retain the delegate until native acknowledgment and receipt persistence
        // have both finished; EOF by itself is not a successful recognition.
        withExtendedLifetime(delegate) {}
        onVolatile(channel.rawValue, "")
    }
}
