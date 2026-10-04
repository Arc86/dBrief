import AVFoundation
import Foundation
import os

/// Owns one mic source's writes and converter. The lock joins an in-flight callback
/// with retirement, then rejects late callbacks from the removed source. This also
/// keeps a stale callback from reopening AudioTrackWriter after the recording closes.
/// `@unchecked Sendable`: mutable state and converter use are protected by lock;
/// incoming buffers are borrowed only for the synchronous receive call.
final class MicCaptureSink: @unchecked Sendable {
    typealias Drain = @Sendable (_ consume: (AVAudioPCMBuffer) -> Void) throws -> Void
    private let lock = NSLock()
    private let writer: AudioTrackWriter
    private let timeline: MicTimeline?
    private let liveSink: AsyncStream<LiveAudioBuffer>.Continuation?
    private let customDrain: Drain?
    /// Fixed by the caller, or created from the first buffer when that buffer's
    /// format differs from the track already on disk (a switched device).
    private var converter: MicFormatConverter?
    private var resolvedFormat: Bool
    private var isFinished = false
    private var receivedAny = false
    private var received: Int64 = 0

    /// Buffers delivered by this source so far — the health signal for a switch.
    /// A silent microphone still delivers buffers; a dead route delivers none.
    var buffersReceived: Int64 { lock.withLock { received } }

    init(writer: AudioTrackWriter, timeline: MicTimeline? = nil, converter: MicFormatConverter? = nil,
         liveSink: AsyncStream<LiveAudioBuffer>.Continuation? = nil, drain: Drain? = nil) {
        self.writer = writer
        self.timeline = timeline
        self.converter = converter
        self.resolvedFormat = converter != nil || drain != nil
        self.liveSink = liveSink
        self.customDrain = drain
    }

    /// - Parameter hostTime: host time of the buffer's first frame, when known.
    ///   Used only to keep an outage between two sources on the track timeline.
    func receive(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        lock.withLock {
            guard !isFinished, buffer.frameLength > 0 else { return }
            received += 1
            if !resolvedFormat { resolveFormat(for: buffer.format) }
            if !receivedAny {
                receivedAny = true
                if let hostTime, let gap = timeline?.gapBefore(hostTime: hostTime) {
                    writer.writeSilence(seconds: gap)
                }
            }
            if let hostTime {
                timeline?.advance(to: hostTime, frames: buffer.frameLength, rate: buffer.format.sampleRate)
            }
            if let converter {
                if let output = converter.convert(buffer) { write(output) }
            } else {
                write(buffer)
            }
        }
    }

    /// Call after the source stops delivering and before taking diagnostics/closing its writer.
    func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            do {
                if let customDrain {
                    try customDrain { write($0) }
                } else if let converter {
                    try converter.finish { write($0) }
                }
            } catch {
                writer.recordConversionFailure()
                Logger.audio.error("Mic converter drain failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func resolveFormat(for format: AVAudioFormat) {
        resolvedFormat = true
        guard let established = writer.establishedFormat,
              established.sampleRate != format.sampleRate || established.channelCount != format.channelCount
        else { return }
        converter = MicFormatConverter(from: format, to: established)
        if converter == nil {
            Logger.audio.error("Mic converter unavailable: \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch → \(established.sampleRate, privacy: .public)Hz")
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

/// The mic track's position on the host clock, shared by every source of one
/// recording. When a device switch replaces the source, the time between the old
/// source's last frame and the new source's first frame is written as silence,
/// so the mic track stays aligned with the continuously captured system track.
final class MicTimeline: @unchecked Sendable {
    /// Smaller gaps are callback jitter at the handover, not an outage.
    static let minimumGap: TimeInterval = 0.05
    /// Larger gaps indicate a clock problem rather than a switch; never pad them.
    static let maximumGap: TimeInterval = 600

    private let lock = NSLock()
    private var endHostTime: UInt64?

    /// Forget the position. Call on pause: both tracks stop, so nothing is missing.
    func reset() {
        lock.withLock { endHostTime = nil }
    }

    fileprivate func gapBefore(hostTime: UInt64) -> TimeInterval? {
        lock.withLock {
            guard let end = endHostTime, hostTime > end else { return nil }
            let gap = AVAudioTime.seconds(forHostTime: hostTime - end)
            return gap >= Self.minimumGap && gap <= Self.maximumGap ? gap : nil
        }
    }

    fileprivate func advance(to hostTime: UInt64, frames: AVAudioFrameCount, rate: Double) {
        guard rate > 0 else { return }
        lock.withLock {
            endHostTime = hostTime + AVAudioTime.hostTime(forSeconds: Double(frames) / rate)
        }
    }
}
