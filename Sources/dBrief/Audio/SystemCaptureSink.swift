import AVFoundation
import CoreMedia
import Foundation
import os

/// One SCStream epoch. Lifecycle retirement is owned by SystemCaptureLifecycle;
/// this lock keeps concurrent callback metadata in the same order as file writes.
final class SystemCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AudioTrackWriter
    private let liveSink: AsyncStream<LiveAudioBuffer>.Continuation?
    private let sourceEpoch = UUID()
    private var emittedFrames = LiveAudioEmissionCounter()

    init(writer: AudioTrackWriter, liveSink: AsyncStream<LiveAudioBuffer>.Continuation?) {
        self.writer = writer
        self.liveSink = liveSink
    }

    /// The caller supplies fresh, exclusively owned PCM from toPCMBuffer().
    func receive(_ pcm: AVAudioPCMBuffer, presentationTime: CMTime) {
        lock.withLock {
            let range = emittedFrames.take(pcm)
            let outcome: LiveAudioWriteOutcome
            do {
                outcome = .receipt(try writer.write(pcm))
            } catch {
                outcome = .failed
                Logger.audio.error("System write error: \(error.localizedDescription, privacy: .public)")
            }
            if let liveSink {
                liveSink.yield(LiveAudioBuffer(pcm, metadata: .init(sourceEpoch: sourceEpoch, role: .system,
                    timestamp: .system(presentationTime), emittedFrames: range,
                    writeOutcome: outcome, converter: nil)))
            }
        }
    }
}
