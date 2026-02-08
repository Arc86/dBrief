import Speech
import os

private let log = Logger(subsystem: "com.voicerecorder.app", category: "localtranscription")

/// On-device transcription using Apple's SFSpeechRecognizer.
actor LocalTranscriptionService {
    func transcribe(fileURL: URL, language: String) async throws -> TranscriptionResult {
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

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let (text, segments) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, [TranscriptionResult.Segment]), Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
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
                    continuation.resume(returning: (text, segs))
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

    var errorDescription: String? {
        switch self {
        case .languageNotSupported: "Speech recognition not available for this language."
        case .notAvailable: "On-device speech recognition is not available."
        }
    }
}
