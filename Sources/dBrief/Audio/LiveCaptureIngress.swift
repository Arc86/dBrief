import Foundation
import AVFoundation
import dBriefWire

/// Immutable receipts identify ownership; all mutable accounting is under one
/// lock, shared by capture callbacks, normalization and the coordinator actor.
final class LiveCaptureIngress: @unchecked Sendable {
    struct Statistics: Sendable {
        let pendingSamples: Int
        let rawBytes: Int
        let nativeSamples: Int
        let converterSamples: Int
    }
    final class RawReservation: @unchecked Sendable {
        let id = UUID()
        let owner: LiveCaptureIngress
        let source: LiveSource
        fileprivate init(owner: LiveCaptureIngress, source: LiveSource) { self.owner = owner; self.source = source }
        func discard(reason: LiveGapReason) { owner.discardRaw(id,reason: reason) }
        deinit { owner.releaseRaw(id,reason: .overload) }
    }
    final class NormalizedReservation: @unchecked Sendable {
        let id = UUID()
        let owner: LiveCaptureIngress
        let scope: LiveLaneScope
        fileprivate init(owner: LiveCaptureIngress, scope: LiveLaneScope) { self.owner = owner; self.scope = scope }
        func contains(_ count: Int) -> Bool { owner.hasUnclaimed(self,count: count) }
        func discard(_ count: Int) -> Bool { owner.discardNormalized(self,count: count) }
        func recordLoss(reason: LiveGapReason) { owner.recordNormalizedLoss(id,reason: reason) }
        deinit { owner.releaseNormalized(id) }
    }
    private struct Raw {
        let source: LiveSource
        let scope: LiveLaneScope
        let metadata: LiveAudioMetadata
        let frames: Int64
        let rate: Int64
        let bytes: Int
        let format: AVAudioFormat?
        var capacity: Int
        var normalized = false
        var lossRecorded = false
        var discarded = false
    }
    private struct Normalized {
        let scope: LiveLaneScope
        let sourceEpoch: UUID
        var remaining: Int
        var lossRecorded = false
    }
    private struct Native {
        var start: Int64
        let end: Int64
        var dispatched = false
    }
    private struct Lane {
        var scope: LiveLaneScope
        var scheduled: Int64 = 0
        var consumed: Int64 = 0
        var native: [Native] = []
        var converterEpoch: UUID?
        var converterOwner: UUID?
        var converterLossRecorded = false
        var converterRate: Int64 = 0
        var converterFrames: Int64 = 0
        var expectedOutput: Int64 = 0
        var emittedOutput: Int64 = 0
        var losses: [LiveCaptureRawLoss] = []
        var continuityLoss: LiveGapReason?
    }
    let input: LiveSessionBegin
    private let lock = NSLock()
    private let sampleLimit: Int
    private let byteLimit: Int
    private let margin: Int
    private let valid: Bool
    private var lanes: [LiveSource: Lane] = [:]
    private var raw: [UUID: Raw] = [:]
    private var normalized: [UUID: Normalized] = [:]
    private var closing = false
    private var retired = false

    init(input: LiveSessionBegin, rawByteLimit: Int = 4 * 1024 * 1024, converterMargin: Int = 4096) {
        self.input = input; sampleLimit = input.configuration.pendingSampleLimit
        byteLimit = rawByteLimit; margin = converterMargin
        valid = input.isValid && rawByteLimit > 0 && rawByteLimit <= 32 * 1024 * 1024 &&
            converterMargin >= 0 && converterMargin < input.configuration.pendingSampleLimit
        for epoch in input.epochs {
            lanes[epoch.source] = .init(scope: .init(identity: input.identity,source: epoch.source,epochID: epoch.id))
        }
    }

    func matches(_ input: LiveSessionBegin) -> Bool { valid && self.input == input }

    /// Loss is an admission latch, independent of draining its evidence inbox.
    /// Only an accepted native replacement clears the current source's latch.
    func continuityLoss(scope: LiveLaneScope) -> LiveGapReason? {
        lock.withLock { lanes[scope.source]?.scope == scope ? lanes[scope.source]?.continuityLoss : nil }
    }

    func claimConverter(scope: LiveLaneScope, owner: UUID) -> Bool {
        lock.withLock {
            guard valid, !retired, var lane = lanes[scope.source], lane.scope == scope,
                  lane.converterOwner == nil, lane.converterEpoch == nil else { return false }
            lane.converterOwner = owner; lanes[scope.source] = lane; return true
        }
    }
    func ownsConverter(scope: LiveLaneScope, owner: UUID) -> Bool {
        lock.withLock { valid && !retired && lanes[scope.source]?.scope == scope && lanes[scope.source]?.converterOwner == owner }
    }

    /// Validate the retained PCM header against the original admission before
    /// allocating converter output. The bound includes this input and the actual
    /// converter's retained capacity, never another lane's native ownership.
    func maximumOutput(_ ticket: RawReservation, scope: LiveLaneScope, metadata: LiveAudioMetadata,
                       frames: Int, rate: Double, bytes: Int, format: AVAudioFormat, converterOwner: UUID) -> Int? {
        lock.withLock {
            guard ticket.owner === self, ticket.source == scope.source, !retired,
                  let item = raw[ticket.id], !item.normalized, !item.discarded, lanes[scope.source]?.scope == scope,
                  lanes[scope.source]?.converterOwner == converterOwner, item.format == format,
                  item.metadata == metadata, item.frames == Int64(frames), Double(item.rate) == rate,
                  item.bytes == bytes else { return nil }
            let held = statisticsWhileLocked(scope.source).converterSamples
            return min(sampleLimit,item.capacity + held + margin)
        }
    }

    func maximumTailOutput(scope: LiveLaneScope, sourceEpoch: UUID) -> Int? {
        lock.withLock {
            guard !retired, let lane = lanes[scope.source], lane.scope == scope,
                  lane.converterEpoch == sourceEpoch else { return nil }
            return min(sampleLimit,Int(max(0,lane.expectedOutput - lane.emittedOutput)) + margin)
        }
    }

    /// EOF output replaces converter-held capacity with an immutable receipt.
    /// Retirement follows only after the real converter has ended or been freed.
    func normalizeTail(scope: LiveLaneScope, sourceEpoch: UUID, emittedSamples: Int) -> NormalizedReservation? {
        lock.withLock {
            guard !retired, var lane = lanes[scope.source], lane.scope == scope,
                  lane.converterEpoch == sourceEpoch, emittedSamples >= 0, emittedSamples <= sampleLimit,
                  normalized.values.filter({ $0.scope.source == scope.source }).count < 64 else { return nil }
            let emitted = lane.emittedOutput.addingReportingOverflow(Int64(emittedSamples))
            let maximum = lane.expectedOutput.addingReportingOverflow(Int64(margin))
            guard !emitted.overflow, !maximum.overflow, emitted.partialValue <= maximum.partialValue else { return nil }
            let oldHeld = Int(max(0,lane.expectedOutput - lane.emittedOutput))
            let held = Int(max(0,lane.expectedOutput - emitted.partialValue))
            guard statisticsWhileLocked(scope.source).pendingSamples - oldHeld + held + emittedSamples <= sampleLimit else { return nil }
            lane.emittedOutput = emitted.partialValue; lanes[scope.source] = lane
            let result = NormalizedReservation(owner: self,scope: scope)
            normalized[result.id] = .init(scope: scope,sourceEpoch: sourceEpoch,remaining: emittedSamples)
            return result
        }
    }

    func reserveRaw(source: LiveSource, metadata: LiveAudioMetadata, frames: Int, rate: Double, bytes: Int,
                    closingTail: Bool = false, format: AVAudioFormat? = nil) -> RawReservation? {
        lock.withLock {
            guard valid, let lane = lanes[source], source.isCaptureSource,
                  (source == .microphone ? metadata.role == .mic : metadata.role == .system) else { return nil }
            guard !retired, !closing || closingTail else {
                lanes[source]?.continuityLoss = .stopped
                addLoss(source,metadata: metadata,reason: .stopped); return nil
            }
            guard frames > 0, bytes > 0, bytes <= byteLimit, rate.isFinite,
                  rate.rounded(.down) == rate, (1...384000).contains(rate),
                  let capacity = Self.capacity(frames: Int64(frames),rate: Int64(rate)),
                  capacity <= sampleLimit,
                  raw.values.filter({ $0.source == source }).count < 64,
                  normalized.values.filter({ $0.scope.source == source }).count < 64,
                  lane.native.count < 128 else {
                lanes[source]?.continuityLoss = .overload
                addLoss(source,metadata: metadata,reason: .overload); return nil
            }
            let stats = statisticsWhileLocked(source)
            guard capacity <= sampleLimit - stats.pendingSamples, bytes <= byteLimit - stats.rawBytes else {
                lanes[source]?.continuityLoss = .overload
                addLoss(source,metadata: metadata,reason: .overload); return nil
            }
            let ticket = RawReservation(owner: self,source: source)
            raw[ticket.id] = .init(source: source,scope: lane.scope,metadata: metadata,frames: Int64(frames),rate: Int64(rate),bytes: bytes,format: format,capacity: capacity)
            return ticket
        }
    }

    /// Capacity arithmetic is not a timeline projection. The cumulative rational
    /// estimate avoids leaking ceil(frameCount * ratio) rounding on every callback.
    /// Raw capacity transfers atomically to converter/output ownership.
    func normalize(_ ticket: RawReservation, scope: LiveLaneScope, emittedSamples: Int) -> NormalizedReservation? {
        lock.withLock {
            guard ticket.owner === self, var item = raw[ticket.id], !item.normalized, !item.discarded,
                  !retired, var lane = lanes[item.source], lane.scope == scope, emittedSamples >= 0,
                  emittedSamples <= sampleLimit,
                  normalized.values.filter({ $0.scope.source == item.source }).count < 64 else { return nil }
            if let converterEpoch = lane.converterEpoch {
                guard converterEpoch == item.metadata.sourceEpoch, lane.converterRate == item.rate else { return nil }
            } else { lane.converterEpoch = item.metadata.sourceEpoch; lane.converterRate = item.rate }
            let frames = lane.converterFrames.addingReportingOverflow(item.frames)
            let emitted = lane.emittedOutput.addingReportingOverflow(Int64(emittedSamples))
            guard !frames.overflow, !emitted.overflow,
                  let expected = Self.capacity64(frames: frames.partialValue,rate: item.rate) else { return nil }
            let maximum = expected.addingReportingOverflow(Int64(margin))
            guard !maximum.overflow, emitted.partialValue <= maximum.partialValue else { return nil }
            let held = Int(max(0,expected - emitted.partialValue))
            guard held <= sampleLimit else { return nil }
            let current = statisticsWhileLocked(item.source)
            let oldHeld = Int(max(0,lane.expectedOutput - lane.emittedOutput))
            let nextPending = current.pendingSamples - item.capacity - oldHeld + held + emittedSamples
            guard nextPending <= sampleLimit else { return nil }
            lane.converterFrames = frames.partialValue; lane.expectedOutput = expected; lane.emittedOutput = emitted.partialValue
            lanes[item.source] = lane
            item.capacity = 0; item.normalized = true; raw[ticket.id] = item
            let result = NormalizedReservation(owner: self,scope: scope)
            normalized[result.id] = .init(scope: scope,sourceEpoch: item.metadata.sourceEpoch,remaining: emittedSamples)
            return result
        }
    }

    /// Only a real converter's EOF/destruction permits returning its retained
    /// capacity. An ASR utterance replacement alone does not retire this converter.
    func retireConverter(source: LiveSource, sourceEpoch: UUID?, owner: UUID) -> Bool {
        lock.withLock {
            guard var lane = lanes[source], lane.converterOwner == owner,
                  sourceEpoch == nil || lane.converterEpoch == sourceEpoch else { return false }
            lane.converterOwner = nil
            lane.converterLossRecorded = false
            lane.converterEpoch = nil; lane.converterRate = 0; lane.converterFrames = 0
            lane.expectedOutput = 0; lane.emittedOutput = 0; lanes[source] = lane
            return true
        }
    }

    func schedule(_ ticket: NormalizedReservation, start: Int64, count: Int) -> Bool {
        lock.withLock {
            guard ticket.owner === self, !retired, var entry = normalized[ticket.id],
                  entry.scope == ticket.scope, var lane = lanes[entry.scope.source], lane.scope == entry.scope,
                  lane.continuityLoss == nil,
                  count > 0, count <= entry.remaining, start == lane.scheduled, lane.native.count < 128 else { return false }
            let end = start.addingReportingOverflow(Int64(count))
            guard !end.overflow else { return false }
            entry.remaining -= count; normalized[ticket.id] = entry
            lane.scheduled = end.partialValue; lane.native.append(.init(start: start,end: end.partialValue))
            lanes[entry.scope.source] = lane; return true
        }
    }

    func markDispatched(scope: LiveLaneScope, end: Int64) -> Bool {
        lock.withLock {
            guard var lane = lanes[scope.source], lane.scope == scope,
                  let index = lane.native.firstIndex(where: { $0.end == end && !$0.dispatched }),
                  lane.native.prefix(index).allSatisfy({ $0.dispatched }) else { return false }
            lane.native[index].dispatched = true; lanes[scope.source] = lane; return true
        }
    }

    func consume(scope: LiveLaneScope, end: Int64) -> Bool {
        lock.withLock {
            guard var lane = lanes[scope.source], lane.scope == scope, end >= lane.consumed,
                  end <= (lane.native.last(where: { $0.dispatched })?.end ?? lane.consumed) else { return false }
            for index in lane.native.indices where lane.native[index].dispatched && lane.native[index].start < end {
                lane.native[index].start = min(end,lane.native[index].end)
            }
            lane.native.removeAll { $0.start == $0.end }
            lane.consumed = end; lanes[scope.source] = lane; return true
        }
    }

    func discardUndispatched(scope: LiveLaneScope) {
        lock.withLock {
            guard lanes[scope.source]?.scope == scope else { return }
            lanes[scope.source]?.native.removeAll { !$0.dispatched }
        }
    }

    /// Invoke only after the helper accepts replacement, which proves its old
    /// native work has unwound. A cut acknowledgment alone is insufficient.
    func replaceEpoch(old: LiveLaneScope, new: LiveEpoch) -> Bool {
        lock.withLock {
            guard !retired, var lane = lanes[old.source], lane.scope == old,
                  new.source == old.source, new.id != old.epochID, new.language == input.configuration.language.rawValue,
                  input.epochs.first(where: { $0.source == new.source })?.engineRevision == new.engineRevision else { return false }
            lane.native.removeAll(); lane.scheduled = 0; lane.consumed = 0
            lane.scope = .init(identity: input.identity,source: new.source,epochID: new.id)
            lane.continuityLoss = nil
            lanes[old.source] = lane; return true
        }
    }

    func closeInput() { lock.withLock { closing = true } }
    func retireInput() {
        lock.withLock {
            guard !retired else { return }
            retired = true
            // Seal facts now, without returning bytes or capacity still held by
            // a consumer. Later release cannot add an unpublishable duplicate.
            for id in raw.keys {
                guard var item = raw[id], !item.normalized, !item.lossRecorded else { continue }
                item.lossRecorded = true; raw[id] = item
                addLoss(item.source,metadata: item.metadata,reason: .stopped)
            }
            for id in normalized.keys { recordNormalizedLossWhileLocked(id,reason: .stopped) }
            for source in lanes.keys {
                if let epoch = lanes[source]?.converterEpoch { recordConverterLossWhileLocked(source,sourceEpoch: epoch,reason: .stopped) }
            }
        }
    }
    /// Only the observed exit of this capture's dedicated process returns held
    /// native credit. This never frees raw buffers still owned by a consumer.
    func confirmNativeRetired() { lock.withLock { for source in lanes.keys { lanes[source]?.native.removeAll() } } }
    func statistics(_ source: LiveSource) -> Statistics { lock.withLock { statisticsWhileLocked(source) } }
    func takeLosses(_ source: LiveSource) -> [LiveCaptureRawLoss] {
        lock.withLock { let losses = lanes[source]?.losses ?? []; lanes[source]?.losses.removeAll(); return losses }
    }

    func recordLoss(source: LiveSource, metadata: LiveAudioMetadata, reason: LiveGapReason) {
        lock.withLock { lanes[source]?.continuityLoss = reason; addLoss(source,metadata: metadata,reason: reason) }
    }
    func recordConverterLoss(source: LiveSource, sourceEpoch: UUID, owner: UUID, reason: LiveGapReason) {
        lock.withLock {
            guard lanes[source]?.converterOwner == owner else { return }
            recordConverterLossWhileLocked(source,sourceEpoch: sourceEpoch,reason: reason)
        }
    }

    private func recordConverterLossWhileLocked(_ source: LiveSource, sourceEpoch: UUID, reason: LiveGapReason) {
        guard let lane = lanes[source], lane.converterOwner != nil, lane.converterEpoch == sourceEpoch,
              lane.converterFrames > 0, !lane.converterLossRecorded else { return }
        lanes[source]?.converterLossRecorded = true
        addLoss(source,metadata: .init(sourceEpoch: sourceEpoch,role: source == .microphone ? .mic : .system,
            timestamp: .unavailable,emittedFrames: nil,writeOutcome: .failed,converter: nil),reason: reason)
    }

    private func hasUnclaimed(_ ticket: NormalizedReservation, count: Int) -> Bool {
        lock.withLock { ticket.owner === self && normalized[ticket.id]?.scope == ticket.scope && count > 0 && count <= (normalized[ticket.id]?.remaining ?? 0) }
    }
    private func discardNormalized(_ ticket: NormalizedReservation, count: Int) -> Bool {
        lock.withLock {
            guard ticket.owner === self, var entry = normalized[ticket.id], count > 0, count <= entry.remaining else { return false }
            entry.remaining -= count; normalized[ticket.id] = entry; return true
        }
    }
    private func releaseNormalized(_ id: UUID) { lock.withLock { normalized[id] = nil } }
    private func recordNormalizedLoss(_ id: UUID, reason: LiveGapReason) {
        lock.withLock { recordNormalizedLossWhileLocked(id,reason: reason) }
    }
    private func recordNormalizedLossWhileLocked(_ id: UUID, reason: LiveGapReason) {
        guard var entry = normalized[id], entry.remaining > 0, !entry.lossRecorded else { return }
        entry.lossRecorded = true; normalized[id] = entry
        addLoss(entry.scope.source,metadata: .init(sourceEpoch: entry.sourceEpoch,
            role: entry.scope.source == .microphone ? .mic : .system,timestamp: .unavailable,
            emittedFrames: nil,writeOutcome: .failed,converter: nil),reason: reason)
    }
    private func releaseRaw(_ id: UUID, reason: LiveGapReason) {
        lock.withLock {
            guard let item = raw.removeValue(forKey: id) else { return }
            if !item.normalized && !item.lossRecorded {
                if lanes[item.source]?.scope == item.scope { lanes[item.source]?.continuityLoss = retired ? .stopped : reason }
                addLoss(item.source,metadata: item.metadata,reason: retired ? .stopped : reason)
            }
        }
    }
    private func discardRaw(_ id: UUID, reason: LiveGapReason) {
        lock.withLock {
            guard var item = raw[id], !item.normalized, !item.discarded else { return }
            if lanes[item.source]?.scope == item.scope { lanes[item.source]?.continuityLoss = retired ? .stopped : reason }
            if !item.lossRecorded { addLoss(item.source,metadata: item.metadata,reason: retired ? .stopped : reason) }
            item.lossRecorded = true; item.discarded = true; item.capacity = 0
            // Discard ends admission, not the retained PCM allocation lifetime.
            // Its bytes and receipt slot return only on the last RAII release.
            raw[id] = item
        }
    }
    private func statisticsWhileLocked(_ source: LiveSource) -> Statistics {
        guard let lane = lanes[source] else { return .init(pendingSamples: 0,rawBytes: 0,nativeSamples: 0,converterSamples: 0) }
        let native = lane.native.reduce(0) { $0 + Int($1.end - $1.start) }
        let converter = Int(max(0,lane.expectedOutput - lane.emittedOutput))
        let rawCapacity = raw.values.filter { $0.source == source }.reduce(0) { $0 + $1.capacity }
        let bytes = raw.values.filter { $0.source == source }.reduce(0) { $0 + $1.bytes }
        let app = normalized.values.filter { $0.scope.source == source }.reduce(0) { $0 + $1.remaining }
        return .init(pendingSamples: margin + rawCapacity + converter + app + native,rawBytes: bytes,nativeSamples: native,converterSamples: converter)
    }
    private func addLoss(_ source: LiveSource, metadata: LiveAudioMetadata, reason: LiveGapReason) {
        guard var lane = lanes[source] else { return }
        let frames = metadata.emittedFrames.flatMap { $0.isValid ? $0 : nil }
        if let last = lane.losses.last, last.sourceEpoch == metadata.sourceEpoch, last.reason == reason,
           let a = last.frames, let b = frames, a.sampleRate == b.sampleRate, a.startFrame + a.frameCount == b.startFrame,
           !a.frameCount.addingReportingOverflow(b.frameCount).overflow {
            lane.losses[lane.losses.count-1] = .init(id: last.id,source: source,sourceEpoch: metadata.sourceEpoch,
                frames: .init(startFrame: a.startFrame,frameCount: a.frameCount + b.frameCount,sampleRate: a.sampleRate),
                reason: reason,bufferCount: last.bufferCount == .max ? .max : last.bufferCount + 1)
        } else if lane.losses.count < 128 {
            lane.losses.append(.init(id: UUID(),source: source,sourceEpoch: metadata.sourceEpoch,frames: frames,reason: reason,bufferCount: 1))
        } else {
            // Keep finite metadata, with an explicit unknown range for overflow.
            let last = lane.losses[lane.losses.count-1]
            lane.losses[lane.losses.count-1] = .init(id: last.id,source: source,sourceEpoch: nil,frames: nil,reason: .overload,
                bufferCount: last.bufferCount == .max ? .max : last.bufferCount + 1)
        }
        lanes[source] = lane
    }
    private static func capacity(frames: Int64, rate: Int64) -> Int? { capacity64(frames: frames,rate: rate).flatMap(Int.init(exactly:)) }
    private static func capacity64(frames: Int64, rate: Int64) -> Int64? {
        let scaled = frames.multipliedReportingOverflow(by: 16000)
        guard frames >= 0, rate > 0, !scaled.overflow else { return nil }
        return scaled.partialValue / rate + (scaled.partialValue % rate == 0 ? 0 : 1)
    }
}
