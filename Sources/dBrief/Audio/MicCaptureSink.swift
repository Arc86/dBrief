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
    private let sourceEpoch = UUID()
    private var emittedFrames = LiveAudioEmissionCounter()
    private var firstInputTimestamp: LiveAudioTimestamp?
    private var latestInputTimestamp: LiveAudioTimestamp = .unavailable
    private var admittedInputFrames: Int64? = 0
    private var inputSampleRate: Double?
    private var inputRateChanged = false

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

    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime? = nil) {
        lock.withLock {
            guard !isFinished else { return }
            let stamp = LiveAudioTimestamp.microphone(time)
            if firstInputTimestamp == nil { firstInputTimestamp = stamp }
            latestInputTimestamp = stamp
            if let admittedInputFrames {
                let next = admittedInputFrames.addingReportingOverflow(Int64(buffer.frameLength))
                self.admittedInputFrames = next.overflow ? nil : next.partialValue
            }
            if let inputSampleRate, inputSampleRate != buffer.format.sampleRate { inputRateChanged = true }
            inputSampleRate = buffer.format.sampleRate
            if let converter {
                if let output = converter.convert(buffer) { write(output, timestamp: .unavailable, isDrain: false) }
            } else {
                write(buffer, timestamp: stamp, isDrain: false)
            }
        }
    }

    /// Call after removing the tap and before taking diagnostics/closing its writer.
    func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            do {
                try drain? { write($0, timestamp: .unavailable, isDrain: true) }
            } catch {
                writer.recordConversionFailure()
                Logger.audio.error("Mic converter drain failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, timestamp: LiveAudioTimestamp, isDrain: Bool) {
        let range = emittedFrames.take(buffer)
        let outcome: LiveAudioWriteOutcome
        do {
            outcome = .receipt(try writer.write(buffer))
        } catch {
            outcome = .failed
            Logger.audio.error("Mic write error: \(error.localizedDescription, privacy: .public)")
        }
        // Engine tap storage is reused. Copy before handing it to an async consumer.
        if let liveSink, let copy = buffer.deepCopy() {
            let context: LiveAudioConverterContext? = converter != nil || isDrain ? .init(
                firstInputTimestamp: firstInputTimestamp ?? .unavailable, latestInputTimestamp: latestInputTimestamp,
                admittedInputFrameCount: admittedInputFrames,
                inputSampleRate: inputRateChanged ? nil : inputSampleRate, isDrain: isDrain) : nil
            liveSink.yield(LiveAudioBuffer(copy, metadata: .init(sourceEpoch: sourceEpoch, role: .mic,
                timestamp: timestamp, emittedFrames: range, writeOutcome: outcome, converter: context)))
        }
    }
}
