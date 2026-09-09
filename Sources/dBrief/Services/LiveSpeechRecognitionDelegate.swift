import Foundation
@preconcurrency import Speech
import dBriefWire

/// Delegate callbacks carry immutable sinks and a lock-protected completion gate.
/// The driver retains this delegate through native terminal acknowledgment.
final class LiveSpeechRecognitionDelegate: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    private let lifecycle: LiveRecognitionCompletion
    private let speaker: String
    private let onFinalized: @Sendable ([LiveTranscriptSegment]) -> Void
    private let onVolatile: @Sendable (String, String) -> Void

    init(lifecycle: LiveRecognitionCompletion, speaker: String,
         onFinalized: @escaping @Sendable ([LiveTranscriptSegment]) -> Void,
         onVolatile: @escaping @Sendable (String, String) -> Void) {
        self.lifecycle = lifecycle
        self.speaker = speaker
        self.onFinalized = onFinalized
        self.onVolatile = onVolatile
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        onVolatile(speaker, transcription.formattedString)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
        lifecycle.observe(.succeeded)
        let segments = result.bestTranscription.segments.map {
            LiveTranscriptSegment(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring, speaker: speaker)
        }
        if !segments.isEmpty { onFinalized(segments) }
        onVolatile(speaker, "")
    }

    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        lifecycle.acknowledge(.cancelled)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        lifecycle.acknowledge(successfully ? .succeeded : (task.isCancelled ? .cancelled : .failed))
    }
}
