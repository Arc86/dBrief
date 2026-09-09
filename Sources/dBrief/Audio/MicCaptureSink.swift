import AVFoundation
import Foundation
import os

/// Owns one tap's writes and converter. The lock joins an in-flight callback with
/// retirement, then rejects late callbacks from the removed tap. This also keeps
/// a stale callback from reopening AudioTrackWriter after the recording closes.
/// `@unchecked Sendable`: mutable state and converter use are protected by lock;
/// incoming engine buffers are borrowed only for the synchronous receive call.
final class MicCaptureSink: @unchecked Sendable {
    typealias Drain = @Sendable (_ consume: (AVAudioPCMBuffer) -> Void) throws -> Void
    private let lock = NSLock()
    private let writer: AudioTrackWriter
    private let converter: MicFormatConverter?
    private let liveSink: AsyncStream<LiveAudioBuffer>.Continuation?
    private let drain: Drain?
    private var isFinished = false

    init(writer: AudioTrackWriter, converter: MicFormatConverter? = nil,
         liveSink: AsyncStream<LiveAudioBuffer>.Continuation? = nil, drain: Drain? = nil) {
        self.writer = writer
        self.converter = converter
        self.liveSink = liveSink
        if let drain {
            self.drain = drain
        } else if let converter {
            self.drain = { consume in try converter.finish(consume: consume) }
        } else {
            self.drain = nil
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isFinished else { return }
            if let converter {
                if let output = converter.convert(buffer) { write(output) }
            } else {
                write(buffer)
            }
        }
    }

    /// Call after removing the tap and before taking diagnostics/closing its writer.
    func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            do {
                try drain? { write($0) }
            } catch {
                writer.recordConversionFailure()
                Logger.audio.error("Mic converter drain failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        do {
            try writer.write(buffer)
        } catch {
            Logger.audio.error("Mic write error: \(error.localizedDescription, privacy: .public)")
        }
        // Engine tap storage is reused. Copy before handing it to an async consumer.
        if let liveSink, let copy = buffer.deepCopy() { liveSink.yield(LiveAudioBuffer(copy)) }
    }
}
