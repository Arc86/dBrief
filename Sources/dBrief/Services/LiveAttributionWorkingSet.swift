import Foundation
import dBriefWire

/// Closed payload accounting, independent from native cost and retained history.
final class LiveAttributionWorkingSet: @unchecked Sendable {
    static let limit = 4 * 1_024 * 1_024
    static let controlBytes = 512 * 1_024
    static let rowBytes = 1_024
    final class Charge: Sendable {
        private let owner: LiveAttributionWorkingSet
        let bytes: Int
        fileprivate init(_ owner: LiveAttributionWorkingSet, _ bytes: Int) { self.owner = owner; self.bytes = bytes }
        deinit { owner.release(bytes) }
    }
    let reservation: LiveRecordingPayloadBudget.Lease
    private let lock = NSLock()
    private var bytes = LiveAttributionWorkingSet.controlBytes
    init(_ reservation: LiveRecordingPayloadBudget.Lease) { self.reservation = reservation }
    var chargedBytes: Int { lock.withLock { bytes } }
    func reserve(_ count: Int) throws -> Charge {
        try lock.withLock {
            guard count > 0, count <= Self.limit - bytes else { throw LiveSpeakerAttributor.Failure.capacity }
            bytes += count; return Charge(self,count)
        }
    }
    private func release(_ count: Int) { lock.withLock { bytes -= count } }
}

/// One raw window and one worker, with at most one held and one queued commit.
/// Immutable snapshots charge raw rows a second time before allocating frames.
final class LiveAttributionWindow: @unchecked Sendable {
    private struct Row: Sendable {
        let scope: LiveLaneScope
        let value: LiveDiarizationRow
        let charge: LiveAttributionWorkingSet.Charge
    }
    private struct Candidate: Sendable {
        let segment: CommittedLiveSegment
        let charge: LiveAttributionWorkingSet.Charge
    }
    private struct Snapshot: Sendable {
        let candidate: Candidate
        let rows: [Row]
        let charge: LiveAttributionWorkingSet.Charge
        let outputCharge: LiveAttributionWorkingSet.Charge
    }
    let working: LiveAttributionWorkingSet
    private let publication: LiveAttributionPublication
    private let context: UUID
    private let beforeEvaluation: @Sendable () async -> Void
    private let publish: @Sendable (LiveSpeakerAttributor.Batch, UInt64) async -> LiveStoreAdmission
    private let failed: @Sendable () -> Void
    private let lock = NSLock()
    private var rows: [Row] = []
    private var pending: Candidate?
    private var sealed = false
    private var waiter: CheckedContinuation<Bool,Never>?
    private var worker: Task<Void,Never>?
    private var sequence: UInt64 = 0
    init(working: LiveAttributionWorkingSet, publication: LiveAttributionPublication, context: UUID,
         beforeEvaluation: @escaping @Sendable () async -> Void,
         publish: @escaping @Sendable (LiveSpeakerAttributor.Batch, UInt64) async -> LiveStoreAdmission,
         failed: @escaping @Sendable () -> Void) {
        self.working = working; self.publication = publication; self.context = context
        self.beforeEvaluation = beforeEvaluation; self.publish = publish; self.failed = failed
    }
    var count: Int { lock.withLock { rows.count } }
    func append(scope: LiveLaneScope, rows incoming: [LiveDiarizationRow]) throws {
        try lock.withLock {
            guard !sealed, publication.isActive, scope.identity == publication.identity, scope.source == .system,
                  (1...2).contains(incoming.count), incoming.allSatisfy(\.isValid) else { throw LiveSpeakerAttributor.Failure.wrongScope }
            for row in incoming {
                // Stream order spans accepted pause epochs; source samples do not.
                guard rows.last.map({ $0.value.streamSamples.end <= row.streamSamples.start }) ?? true else {
                    throw LiveSpeakerAttributor.Failure.invalidInput
                }
                let oldest = max(0,row.streamSamples.end - 480_000)
                rows.removeAll { $0.value.streamSamples.end <= oldest }
                if rows.count == LiveSpeakerAttributor.maximumFrames { rows.removeFirst() }
                let charge = try working.reserve(LiveAttributionWorkingSet.rowBytes)
                rows.append(.init(scope: scope,value: row,charge: charge))
            }
        }
    }
    /// Called without suspension only after the actual mapped commit is accepted.
    func offer(_ segment: CommittedLiveSegment) -> Bool {
        do {
            return try lock.withLock {
                guard !sealed, publication.isActive, segment.source == .system, segment.diarizerContextID == context,
                      segment.words.count <= LiveSpeakerAttributor.maximumWords, pending == nil else { return false }
                let bytes = try LiveArtifactEncoding.estimatedBytes(segment,limit: LiveAttributionWorkingSet.limit / 4) * 4
                pending = .init(segment: segment,charge: try working.reserve(max(1,bytes)))
                if worker == nil { worker = Task { await self.run() } }
                let waiting = waiter; waiter = nil; waiting?.resume(returning: true)
                return true
            }
        } catch { return false }
    }
    func seal() {
        let waiting = lock.withLock { sealed = true; rows.removeAll(); pending = nil; let waiting = waiter; waiter = nil; return waiting }
        waiting?.resume(returning: false)
        // Held snapshots and their original worker are not released by this seal.
    }
    func finish() async { seal(); let original = lock.withLock { worker }; await original?.value }
    private func next() throws -> Snapshot? {
        try lock.withLock {
            guard !sealed, publication.isActive, let candidate = pending else {
                pending = nil; return nil
            }
            // Preflight independent COW/raw + evaluator expansion and a bounded
            // worst-case output before making any snapshot/evaluator arrays.
            let rowCharge = try working.reserve(max(1,rows.count * LiveAttributionWorkingSet.rowBytes))
            let outputCharge = try working.reserve((candidate.segment.words.count + 1) * 2_048 + 16_384)
            let snapshot = Snapshot(candidate: candidate,rows: rows,charge: rowCharge,outputCharge: outputCharge)
            pending = nil; return snapshot
        }
    }
    private func waitReady() async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool? in
                if sealed || !publication.isActive { return false }
                if pending != nil { return true }
                precondition(waiter == nil); waiter = continuation; return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
    private func run() async {
        do {
            while await waitReady() {
                guard let snapshot = try next() else { break }
                await beforeEvaluation()
                guard publication.isActive else { break }
                let segment = snapshot.candidate.segment
                let lower = segment.range.meeting.map { $0.endNanoseconds.mapLowerBound } ?? 0
                var recorded: [LiveMeetingRange] = [], frames: [LiveSpeakerAttributor.Frame] = []
                for row in snapshot.rows {
                    guard let meeting = row.value.meeting, meeting.endNanoseconds > lower else { continue }
                    if let prior = recorded.last, prior.endNanoseconds == meeting.startNanoseconds {
                        recorded[recorded.count - 1] = .init(startNanoseconds: prior.startNanoseconds,endNanoseconds: meeting.endNanoseconds)
                    } else { recorded.append(meeting) }
                    guard recorded.count <= LiveSpeakerAttributor.maximumRecordedRanges else { throw LiveSpeakerAttributor.Failure.capacity }
                    frames.append(.init(meeting: meeting,activity: try row.value.activityValues().map(Double.init)))
                }
                let evaluator = try LiveSpeakerAttributor(identity: publication.identity,source: .system,contextID: context,policy: .init())
                let batch = try evaluator.evaluate(segment,timings: segment.words.indices.map { .emission(wordIndex: $0) },
                    window: .init(identity: publication.identity,source: .system,contextID: context,recorded: recorded,frames: frames))
                guard try LiveArtifactEncoding.estimatedBytes(batch,limit: snapshot.outputCharge.bytes / 4) * 4 <= snapshot.outputCharge.bytes,
                      publication.isActive else { throw LiveSpeakerAttributor.Failure.capacity }
                let result = await publish(batch,sequence)
                withExtendedLifetime(snapshot) {}
                guard result == .accepted || result == .duplicate, sequence < .max else { throw LiveSpeakerAttributor.Failure.invalidInput }
                sequence += 1
            }
        } catch { failed() }
        seal()
    }
}
private extension Int64 {
    var mapLowerBound: Int64 { Swift.max(0,self - LiveSpeakerAttributor.maximumWindowNanoseconds) }
}
