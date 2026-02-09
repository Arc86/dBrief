import Foundation
import Speech
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "localtranscription")

/// On-device transcription using Apple's SFSpeechRecognizer.
actor LocalTranscriptionService {
    func transcribe(fileURL: URL, language: String) async throws -> TranscriptionResult {
        let preparedURL = try prepareTranscriptionURL(for: fileURL)
        let locale: Locale
        if language.isEmpty {
            locale = .current
        } else {
            locale = Locale(identifier: language)
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw LocalTranscriptionError.languageNotSupported
        }
        guard recognizer.isAvailable else {
            throw LocalTranscriptionError.notAvailable
        }

        let request = SFSpeechURLRecognitionRequest(url: preparedURL)
        // Allow Apple Speech to choose on-device or server recognition for better compatibility.
        request.requiresOnDeviceRecognition = false
        request.shouldReportPartialResults = true

        let (text, segments) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, [TranscriptionResult.Segment]), Error>) in
            let lock = NSLock()
            var didResume = false
            var recognitionTask: SFSpeechRecognitionTask?
            let timeoutWorkItem = DispatchWorkItem {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                recognitionTask?.cancel()
                didResume = true
                continuation.resume(throwing: LocalTranscriptionError.timeout)
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + 10 * 60,
                execute: timeoutWorkItem
            )

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                lock.lock()
                guard !didResume else {
                    lock.unlock()
                    return
                }

                if let error {
                    if let result {
                        let text = result.bestTranscription.formattedString
                        let segs = result.bestTranscription.segments.map { seg in
                            TranscriptionResult.Segment(
                                start: seg.timestamp,
                                end: seg.timestamp + seg.duration,
                                text: seg.substring
                            )
                        }
                        didResume = true
                        lock.unlock()
                        timeoutWorkItem.cancel()
                        continuation.resume(returning: (text, segs))
                        return
                    }
                    didResume = true
                    lock.unlock()
                    timeoutWorkItem.cancel()
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    let segs = result.bestTranscription.segments.map { seg in
                        TranscriptionResult.Segment(
                            start: seg.timestamp,
                            end: seg.timestamp + seg.duration,
                            text: seg.substring
                        )
                    }
                    didResume = true
                    lock.unlock()
                    timeoutWorkItem.cancel()
                    continuation.resume(returning: (text, segs))
                } else {
                    lock.unlock()
                }
            }
        }
        log.info("Local transcription complete: \(text.prefix(80), privacy: .public)...")

        return TranscriptionResult(
            text: text,
            segments: segments,
            language: language.isEmpty ? nil : language
        )
    }

    private func prepareTranscriptionURL(for fileURL: URL) throws -> URL {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "ogg" || ext == "opus" else {
            return fileURL
        }

        // Convert OGG/Opus to WAV using ffmpeg for on-device transcription.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("debrief-transcription-\(UUID().uuidString).wav")

        let ffmpegPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]

        let resolvedPath = ffmpegPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        let process = Process()
        if let resolvedPath {
            process.executableURL = URL(fileURLWithPath: resolvedPath)
            process.arguments = [
                "-y",
                "-i", fileURL.path,
                "-ac", "1",
                "-ar", "16000",
                "-f", "wav",
                outputURL.path,
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "ffmpeg",
                "-y",
                "-i", fileURL.path,
                "-ac", "1",
                "-ar", "16000",
                "-f", "wav",
                outputURL.path,
            ]
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]
        }

        let stdErr = Pipe()
        process.standardError = stdErr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LocalTranscriptionError.ffmpegNotFound
        }

        guard process.terminationStatus == 0 else {
            let data = stdErr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ffmpeg failed"
            throw LocalTranscriptionError.conversionFailed(message)
        }

        return outputURL
    }

    static func requestAccess() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static var isAvailable: Bool {
        SFSpeechRecognizer()?.isAvailable ?? false
    }
}

enum LocalTranscriptionError: Error, LocalizedError {
    case languageNotSupported
    case notAvailable
    case ffmpegNotFound
    case conversionFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .languageNotSupported: "Speech recognition not available for this language."
        case .notAvailable: "On-device speech recognition is not available."
        case .ffmpegNotFound: "ffmpeg is required to transcribe .ogg/.opus files. Install ffmpeg and try again."
        case .conversionFailed(let message): "Failed to convert audio for transcription. \(message)"
        case .timeout: "Speech recognition timed out. Try a shorter clip or external transcription."
        }
    }
}
