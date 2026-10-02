import AVFoundation
import CoreMedia
import Foundation
import dBriefWire

enum AudioTrackWriteReceipt: Sendable, Equatable {
    enum DropReason: Sendable { case formatMismatch }
    case written(startFrame: Int64, frameCount: Int64, sampleRate: Double)
    case dropped(DropReason)
}

enum LiveAudioWriteOutcome: Sendable, Equatable {
    case receipt(AudioTrackWriteReceipt)
    case failed
}

enum LiveAudioTimestamp: Sendable, Equatable {
    case unavailable
    case microphone(hostTime: UInt64?, sampleTime: Int64?, sampleRate: Double?)
    case systemPTS(value: Int64, timescale: Int32, epoch: Int64)
    static func microphone(_ time: AVAudioTime?) -> Self {
        guard let time, time.isHostTimeValid || time.isSampleTimeValid else { return .unavailable }
        return .microphone(hostTime: time.isHostTimeValid ? time.hostTime : nil,
                           sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                           sampleRate: time.isSampleTimeValid ? time.sampleRate : nil)
    }
    static func system(_ pts: CMTime) -> Self {
        guard pts.isNumeric, pts.timescale > 0 else { return .unavailable }
        return .systemPTS(value: pts.value, timescale: pts.timescale, epoch: pts.epoch)
    }
}

/// Input stamps describe converter context, not the origin of delayed output.
/// The input count is admission to the converter, not proof of native consumption.
struct LiveAudioConverterContext: Sendable, Equatable {
    let firstInputTimestamp: LiveAudioTimestamp
    let latestInputTimestamp: LiveAudioTimestamp
    let admittedInputFrameCount: Int64?
    let inputSampleRate: Double?
    let isDrain: Bool
    var alignmentVerified: Bool { false }
}

struct LiveAudioMetadata: Sendable, Equatable {
    let sourceEpoch: UUID
    let role: AudioTrackWriter.Role
    /// Exact callback stamp only for unconverted buffers; unavailable for tails.
    let timestamp: LiveAudioTimestamp
    /// Output frames within this source epoch, independent of the file writer.
    let emittedFrames: LiveAudioFrameRange?
    let writeOutcome: LiveAudioWriteOutcome
    let converter: LiveAudioConverterContext?
}

/// Confined to a capture sink's lock. An unexpected rate change or overflow
/// invalidates the epoch counter rather than fabricating continuous coordinates.
struct LiveAudioEmissionCounter {
    private var nextFrame: Int64? = 0
    private var sampleRate: Double?

    mutating func take(_ buffer: AVAudioPCMBuffer) -> LiveAudioFrameRange? {
        let rate = buffer.format.sampleRate
        guard rate.isFinite, rate > 0, sampleRate == nil || sampleRate == rate, let start = nextFrame else {
            nextFrame = nil
            return nil
        }
        sampleRate = rate
        let count = Int64(buffer.frameLength), end = start.addingReportingOverflow(count)
        guard !end.overflow else { nextFrame = nil; return nil }
        nextFrame = end.partialValue
        return .init(startFrame: start, frameCount: count, sampleRate: rate)
    }
}

typealias LiveAudioFrameRange = LiveRawFrameRange

struct LiveAudioTimeRange: Codable, Sendable, Equatable {
    let startNanoseconds: Int64
    let endNanoseconds: Int64
}

struct LiveAudioClockAnchor: Sendable {
    let sourceEpoch: UUID
    let sourceFrame: Int64
    let hostNanoseconds: Int64
    let sampleRate: Int64
    let verified: Bool
}

struct LiveAudioProjection: Sendable, Equatable {
    let meeting: LiveAudioTimeRange?
    let savedTrack: LiveAudioFrameRange?
}

enum LiveAudioTimelineError: Error { case invalidClock }

struct LiveAudioTimeline: Sendable {
    let originNanoseconds: Int64
    let pauses: [LiveAudioTimeRange]
    init(originNanoseconds: Int64, pauses: [LiveAudioTimeRange] = []) throws {
        guard originNanoseconds >= 0 else { throw LiveAudioTimelineError.invalidClock }
        var previousEnd = originNanoseconds
        for pause in pauses {
            guard pause.startNanoseconds >= previousEnd, pause.endNanoseconds > pause.startNanoseconds else {
                throw LiveAudioTimelineError.invalidClock
            }
            previousEnd = pause.endNanoseconds
        }
        self.originNanoseconds = originNanoseconds
        self.pauses = pauses
    }
    func project(sourceFrames: LiveAudioFrameRange, sourceEpoch: UUID, anchor: LiveAudioClockAnchor?,
                 outcome: LiveAudioWriteOutcome, conversionAlignmentVerified: Bool) -> LiveAudioProjection {
        var saved: LiveAudioFrameRange?
        if case let .receipt(.written(start, count, rate)) = outcome {
            let range = LiveAudioFrameRange(startFrame: start, frameCount: count, sampleRate: rate)
            if range.isValid { saved = range }
        }
        // A successful file write proves only its saved-track coordinates. Clock
        // eligibility and converter latency are separate evidence requirements.
        guard conversionAlignmentVerified, sourceFrames.isValid, let anchor,
              anchor.verified, anchor.sourceEpoch == sourceEpoch, anchor.sourceFrame >= 0,
              sourceFrames.startFrame >= anchor.sourceFrame,
              sourceFrames.sampleRate == Double(anchor.sampleRate),
              anchor.hostNanoseconds >= originNanoseconds else {
            return .init(meeting: nil, savedTrack: saved)
        }
        let startOffset = sourceFrames.startFrame - anchor.sourceFrame
        let endOffset = startOffset.addingReportingOverflow(sourceFrames.frameCount)
        guard !endOffset.overflow,
              let startDelta = Self.nanoseconds(frames: startOffset, rate: anchor.sampleRate, roundUp: false),
              let endDelta = Self.nanoseconds(frames: endOffset.partialValue, rate: anchor.sampleRate, roundUp: true) else {
            return .init(meeting: nil, savedTrack: saved)
        }
        let start = anchor.hostNanoseconds.addingReportingOverflow(startDelta)
        let end = anchor.hostNanoseconds.addingReportingOverflow(endDelta)
        // Capture counters concatenate admitted frames across a pause. An old
        // anchor cannot extrapolate through that missing host-clock interval;
        // resume needs a fresh verified anchor even if the source epoch survives.
        guard !start.overflow, !end.overflow,
              !pauses.contains(where: { anchor.hostNanoseconds < $0.endNanoseconds && end.partialValue > $0.startNanoseconds }),
              let activeStart = activeNanoseconds(start.partialValue),
              let activeEnd = activeNanoseconds(end.partialValue) else {
            return .init(meeting: nil, savedTrack: saved)
        }
        return .init(meeting: .init(startNanoseconds: activeStart, endNanoseconds: activeEnd), savedTrack: saved)
    }

    /// Split whole seconds/remainder to avoid overflowing a long frame counter
    /// before dividing. Bounds above make the remainder multiplication safe.
    private static func nanoseconds(frames: Int64, rate: Int64, roundUp: Bool) -> Int64? {
        guard frames >= 0, rate > 0, rate <= 384000 else { return nil }
        let whole = (frames / rate).multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return nil }
        let numerator = (frames % rate) * 1_000_000_000
        let fractional = numerator / rate + (roundUp && numerator % rate != 0 ? 1 : 0)
        let total = whole.partialValue.addingReportingOverflow(fractional)
        return total.overflow ? nil : total.partialValue
    }

    private func activeNanoseconds(_ host: Int64) -> Int64? {
        guard host >= originNanoseconds else { return nil }
        var active = host - originNanoseconds
        for pause in pauses where pause.endNanoseconds <= host {
            let duration = pause.endNanoseconds - pause.startNanoseconds
            guard active >= duration else { return nil }
            active -= duration
        }
        return active
    }
}
