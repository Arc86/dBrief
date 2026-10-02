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
    private let liveIngress: LiveCaptureIngress?
    private let sourceEpoch = UUID()
    private var emittedFrames = LiveAudioEmissionCounter()

    init(writer: AudioTrackWriter, liveSink: AsyncStream<LiveAudioBuffer>.Continuation?, liveIngress: LiveCaptureIngress? = nil) {
        self.writer = writer
        self.liveSink = liveSink
        self.liveIngress = liveIngress
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
                let metadata = LiveAudioMetadata(sourceEpoch: sourceEpoch, role: .system,
                    timestamp: .system(presentationTime), emittedFrames: range,
                    writeOutcome: outcome, converter: nil)
                var reservation: LiveCaptureIngress.RawReservation?
                if let liveIngress {
                    guard let bytes = pcm.liveAllocationBytes(compact: false) else {
                        liveIngress.recordLoss(source: .system,metadata: metadata,reason: .unavailable); return
                    }
                    guard let admitted = liveIngress.reserveRaw(source: .system,metadata: metadata,
                        frames: Int(pcm.frameLength),rate: pcm.format.sampleRate,bytes: bytes) else { return }
                    reservation = admitted
                }
                liveSink.yield(LiveAudioBuffer(pcm,metadata: metadata,ingress: reservation))
            }
        }
    }
}
