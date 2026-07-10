import Foundation
import dBriefWire

/// A single background processing job (finalize → transcribe → AI → markdown →
/// integrations) for one recording. Decouples "something is processing" from the
/// capture state machine (`AppState.recordingState`) so a new recording can start
/// while a previous one is still being processed.
///
/// Only ever **one** job is live at a time — overflow (a second recording finished
/// before the current job completes) is deferred to the on-disk `.queue.json` queue
/// and drained one-at-a-time. That invariant is why the job's *progress* still lives
/// as `AppState` singletons (`processingSteps`, `liveInferenceText`): they always
/// describe this one job. The job carries only the state that genuinely conflicts
/// with a concurrent capture.
@MainActor
@Observable
final class ProcessingJob {
    /// The recording being processed. Held here (not read from `AppState.currentRecording`,
    /// which the capture slot may have overwritten with a newer recording).
    let recording: Recording

    /// The job's own pipeline task. A confirm-first speaker review makes the pipeline
    /// return early and resume later via the review window; the resumed analysis must
    /// run inside this handle so `cancelProcessing()` can cancel the *whole* job and the
    /// auto-drain can't start a second job while a resumed analysis is still running.
    var task: Task<Void, Never>?

    /// The finalized audio URL when this job came from the on-disk queue. Completion
    /// removes the matching `.queue.json` sidecar (via `removeQueueFile(for:)`) before
    /// draining the next item, so the just-finished item isn't re-discovered.
    var queuedAudioURL: URL?

    /// Progressive ("In Progress") transcript segments emitted by WhisperKit during
    /// *this* job — kept off the shared `AppState.liveTranscriptSegments`, which is
    /// reserved for a concurrently-active capture's live preview.
    var progressiveSegments: [LiveTranscriptSegment] = []

    /// When actual transcription (not model download/load) began, used to drive the
    /// live progress/ETA estimate. Set on the engine's first "transcribing" signal
    /// (or at call time for engines with no in-app download phase), and cleared when
    /// transcription proper ends (e.g. the vocabulary-correction post-step begins) so
    /// the ETA ticker stops writing.
    var transcriptionStartedAt: Date?

    init(recording: Recording, queuedAudioURL: URL? = nil) {
        self.recording = recording
        self.queuedAudioURL = queuedAudioURL
    }
}
