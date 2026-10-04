import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveAttributionAdmissionTests {
    private let megabyte = 1_024 * 1_024
    private func key(_ f: LiveTranscriptFixture, _ context: UUID, _ slot: Int = 0) -> SpeakerTrackKey {
        .init(captureSessionID: f.identity.captureSessionID, source: .microphone, contextID: context, slot: slot)
    }
    private func seed(_ f: LiveTranscriptFixture, _ store: LiveTranscriptStore, _ context: UUID) async throws -> (LiveEpoch, CommittedLiveSegment) {
        let epoch = f.epoch(), base = f.segment(epoch, 0, 0, 1, "one", context: context)
        let segment = CommittedLiveSegment(id: base.id, source: base.source, range: base.range, text: base.text,
            words: [.init(text: "one", samples: nil, confidence: 1)], diarizerContextID: context)
        try #require(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        try #require(await store.registerDiarizer(owner: f.identity, source: .microphone, contextID: context) == .accepted)
        try #require(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        try #require(await store.admit(f.event(epoch, 1, .committed(segment))) == .accepted)
        return (epoch, segment)
    }

    @Test func exhaustedLabelsDoNotSpendOrRetireTheRemainingTextBudget() async throws {
        let f = LiveTranscriptFixture(), context = UUID(), store = LiveTranscriptStore(identity: f.identity, retainedEvidenceLimit: 65_536)
        let (epoch, segment) = try await seed(f, store, context), before = await store.retainedEvidenceBytes
        var accepted: UInt64 = 0
        for sequence in 0..<4_096 {
            let result = await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: UInt64(sequence),
                annotations: [.init(segmentID: segment.id, wordIndex: 0, assignment: .track(key(f, context, sequence % 2)))])
            if result == .rejected(.capacity) { break }
            try #require(result == .accepted); accepted += 1
        }
        try #require(accepted > 0 && accepted < 4_096)
        #expect(await store.retainedEvidenceBytes == before)
        #expect(!(await store.evidenceGrowthRetired))
        let frozen = await store.checkpoint()
        #expect(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: accepted,
            annotations: [.init(segmentID: segment.id, wordIndex: 0, assignment: .unknown)]) == .rejected(.capacity))
        #expect(await store.checkpoint() == frozen)
        #expect(await store.admit(f.event(epoch, 2, f.progress(2))) == .accepted)
        #expect(await store.admit(f.event(epoch, 3, .committed(f.segment(epoch, 1, 1, 2, "Text continues", context: context)))) == .accepted)
        #expect(await store.close(owner: f.identity) == .accepted)
    }

    @Test func contextRegistrationAndExactReplayHaveAnIndependentQuota() async throws {
        let f = LiveTranscriptFixture(), store = LiveTranscriptStore(identity: f.identity, retainedEvidenceLimit: 65_536), epoch = f.epoch()
        try #require(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        let before = await store.retainedEvidenceBytes, revision = await store.checkpoint().revision
        var last = UUID(), count = 0
        for _ in 0..<4_096 {
            let context = UUID(), result = await store.registerDiarizer(owner: f.identity, source: .microphone, contextID: context)
            if result == .rejected(.capacity) { break }
            try #require(result == .accepted); last = context; count += 1
        }
        try #require(count > 0 && count < 4_096)
        #expect(await store.registerDiarizer(owner: f.identity, source: .microphone, contextID: last) == .duplicate)
        #expect(await store.retainedEvidenceBytes == before)
        #expect(!(await store.evidenceGrowthRetired))
        #expect(await store.checkpoint().revision == revision)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1, context: last)))) == .accepted)
    }

    @Test func mandatoryRetirementDoesNotResurrectTextOrRejectRetainedWordAnnotations() async throws {
        let f = LiveTranscriptFixture(), context = UUID(), store = LiveTranscriptStore(identity: f.identity, retainedEvidenceLimit: 65_536)
        let (epoch, segment) = try await seed(f, store, context)
        #expect(await store.admit(f.event(epoch, 2, f.progress(2))) == .accepted)
        #expect(await store.admit(f.event(epoch, 3, .committed(f.segment(epoch, 1, 1, 2, String(repeating: "x", count: 65_536))))) == .rejected(.capacity))
        try #require(await store.evidenceGrowthRetired)
        #expect(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0,
            annotations: [.init(segmentID: segment.id, wordIndex: 0, assignment: .track(key(f, context)))]) == .accepted)
        #expect(await store.evidenceGrowthRetired)
        #expect(await store.admit(f.event(epoch, 3, .committed(f.segment(epoch, 1, 1, 2, "Small")))) == .rejected(.capacity))
    }

    @Test func sharedRoomFailureRejectsOnlyOptionalWorkAndRemainsSticky() async throws {
        let files = try LiveArtifactFixture(); defer { files.remove() }
        let budget = LiveRecordingPayloadBudget(ownerLimit: 8)
        let registry = LiveRecordingSessionRegistry(artifactRoot: files.root, payloadBudget: budget), entry = try registry.register(files.identity)
        let epoch = LiveEpoch(id: UUID(), source: .microphone, engineRevision: "fixture", language: "auto", meetingOriginNanoseconds: 0)
        try #require(await entry.store.beginEpoch(owner: files.identity, epoch: epoch) == .accepted)
        var blocker: LiveRecordingPayloadBudget.Lease? = try budget.reserveAuxiliary(bytes: 128 * megabyte - budget.reservedBytes)
        let before = await entry.store.retainedEvidenceBytes
        #expect(await entry.store.registerDiarizer(owner: files.identity, source: .microphone, contextID: UUID()) == .rejected(.capacity))
        #expect(await entry.store.retainedEvidenceBytes == before)
        #expect(!(await entry.store.evidenceGrowthRetired))
        blocker = nil
        #expect(await entry.store.registerDiarizer(owner: files.identity, source: .microphone, contextID: UUID()) == .rejected(.capacity))
        #expect(await entry.store.admit(.init(identity: files.identity, epochID: epoch.id, source: .microphone, sequence: 0,
            payload: .progress(.init(capturedSampleEnd: 16_000, admittedSampleEnd: 16_000, consumedSampleEnd: 16_000)))) == .accepted)
        #expect(await entry.store.admit(.init(identity: files.identity, epochID: epoch.id, source: .microphone, sequence: 1,
            payload: .committed(.init(id: .init(epochID: epoch.id, index: 0), source: .microphone,
                range: .init(samples: .init(start: 0, end: 16_000), meeting: .init(startNanoseconds: 0, endNanoseconds: 1_000_000_000)), text: "Audio's text continues")))) == .accepted)
        withExtendedLifetime(blocker) {}
    }

    @Test func oneMutableStoreAndOnlyAnOwnerLeaseMayClaimOptionalAllowance() async throws {
        let f = LiveTranscriptFixture(), budget = LiveRecordingPayloadBudget(ownerLimit: 2), lease = try budget.reserve()
        let first = LiveTranscriptStore(identity: f.identity, payloadReservation: lease), second = LiveTranscriptStore(identity: f.identity, payloadReservation: lease)
        let epoch = f.epoch(), context = UUID()
        try #require(await first.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        try #require(await second.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await first.registerDiarizer(owner: f.identity, source: .microphone, contextID: context) == .accepted)
        #expect(budget.reservedBytes == 33 * megabyte)
        #expect(await second.registerDiarizer(owner: f.identity, source: .microphone, contextID: context) == .rejected(.capacity))
        let auxiliary = try budget.reserveAuxiliary(bytes: megabyte), third = LiveTranscriptStore(identity: f.identity, payloadReservation: auxiliary)
        try #require(await third.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await third.registerDiarizer(owner: f.identity, source: .microphone, contextID: context) == .rejected(.capacity))
        #expect(budget.reservedBytes == 34 * megabyte)
    }

    @Test func invalidBatchAndDuplicateDoNotSpendEitherAllowanceOrChangeTheFrozenRevision() async throws {
        let f = LiveTranscriptFixture(), context = UUID(), store = LiveTranscriptStore(identity: f.identity, retainedEvidenceLimit: 65_536)
        let (_, segment) = try await seed(f, store, context), before = await store.retainedEvidenceBytes, checkpoint = await store.checkpoint()
        #expect(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0,
            annotations: [.init(segmentID: segment.id, wordIndex: 0, assignment: .track(key(f, context, 8)))]) == .rejected(.invalidAnnotation))
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: context, sequence: 0, annotations: []) == .rejected(.invalidAnnotation))
        #expect(await store.checkpoint() == checkpoint)
        #expect(await store.retainedEvidenceBytes == before)
        let annotations = [LiveSpeakerAnnotation(segmentID: segment.id, wordIndex: 0, assignment: .track(key(f, context)))]
        #expect(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0, annotations: annotations) == .accepted)
        let accepted = await store.checkpoint()
        #expect(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0, annotations: annotations) == .duplicate)
        #expect(await store.checkpoint() == accepted)
        #expect(await store.retainedEvidenceBytes == before)
    }

    @Test func retiredLookupKeepsTheAuxiliaryAllowanceUntilHeldWriterWorkActuallyReturns() async throws {
        let files = try LiveArtifactFixture(); defer { files.remove() }
        let gate = LiveArtifactGate(stage: .sourceTranscript), registry = LiveRecordingSessionRegistry(artifactRoot: files.root, beforeStage: { try await gate.enter($0) })
        var entry: LiveRecordingSessionRegistry.Entry? = try registry.register(files.identity)
        let epoch = LiveEpoch(id: UUID(), source: .microphone, engineRevision: "fixture", language: "auto", meetingOriginNanoseconds: 0)
        try #require(await entry?.store.beginEpoch(owner: files.identity, epoch: epoch) == .accepted)
        try #require(await entry?.store.registerDiarizer(owner: files.identity, source: .microphone, contextID: UUID()) == .accepted)
        let catalogue = LiveManagedArtifactCatalogue.metadataBytes
        #expect(registry.reservedPayloadBytes == 33 * megabyte + catalogue)
        var flush: Task<Void, Error>?
        do {
            registry.startPersistence(files.identity)
            flush = Task { [owner = try #require(entry).artifacts] in try await owner.flush() }
            try await gate.waitForArrival()
            try registry.retire(files.identity); entry = nil
            #expect(registry.reservedPayloadBytes == 33 * megabyte + catalogue)
            flush?.cancel()
            #expect(registry.reservedPayloadBytes == 33 * megabyte + catalogue)
            await gate.release(); _ = try? await flush?.value; flush = nil
            try await files.eventually { await MainActor.run { registry.reservedPayloadBytes == catalogue } }
        } catch {
            await gate.release(); try? registry.retire(files.identity); _ = try? await flush?.value; throw error
        }
    }

    @Test func distinctNearQuotaLabelsAndFullTerminalInventoryRemainDurableAndColdReloadable() async throws {
        let files = try LiveArtifactFixture(); defer { files.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: files.root), entry = try registry.register(files.identity), owner = UUID(), context = UUID()
        try #require(entry.store.bindCaptureOwner(owner, accepting: { true }))
        let epoch = LiveEpoch(id: UUID(), source: .microphone, engineRevision: String(repeating: "r", count: 256), language: String(repeating: "l", count: 32), meetingOriginNanoseconds: nil)
        try #require(await entry.store.beginEpoch(owner: files.identity, epoch: epoch) == .accepted)
        try #require(await entry.store.registerDiarizer(owner: files.identity, source: .microphone, contextID: context) == .accepted)
        try #require(await entry.store.admit(.init(identity: files.identity, epochID: epoch.id, source: .microphone, sequence: 0,
            payload: .progress(.init(capturedSampleEnd: 1_000, admittedSampleEnd: 1_000, consumedSampleEnd: 1_000)))) == .accepted)
        let segment = CommittedLiveSegment(id: .init(epochID: epoch.id, index: 0), source: .microphone,
            range: .init(samples: .init(start: 0, end: 1), meeting: nil), text: (0..<64).map { "word\($0)" }.joined(separator: " "),
            words: (0..<64).map { .init(text: "word\($0)", samples: nil) }, diarizerContextID: context)
        try #require(await entry.store.admit(.init(identity: files.identity, epochID: epoch.id, source: .microphone, sequence: 1, payload: .committed(segment))) == .accepted)
        let tracks = (0..<8).map { SpeakerTrackKey(captureSessionID: files.identity.captureSessionID, source: .microphone, contextID: context, slot: $0) }
        var labels = 0
        for word in segment.words.indices {
            let result = await entry.store.annotate(owner: files.identity, source: .microphone, contextID: context, sequence: UInt64(word),
                annotations: [.init(segmentID: segment.id, wordIndex: word, assignment: .overlap(tracks))])
            if result == .rejected(.capacity) { break }
            try #require(result == .accepted); labels += 1
        }
        try #require(labels > 16 && labels < 64)
        #expect(!(await entry.store.evidenceGrowthRetired))
        var committed: UInt64 = 1
        for index in 1..<16 {
            let result = await entry.store.admit(.init(identity: files.identity, epochID: epoch.id, source: .microphone, sequence: UInt64(index + 1),
                payload: .committed(.init(id: .init(epochID: epoch.id, index: UInt64(index)), source: .microphone,
                    range: .init(samples: .init(start: Int64(index), end: Int64(index + 1)), meeting: nil), text: String(repeating: "x", count: 10_000)))))
            if result == .rejected(.capacity) { break }
            try #require(result == .accepted); committed += 1
        }
        try #require(await entry.store.evidenceGrowthRetired)
        try #require(await entry.store.admitTerminal(owner: owner, event: .init(identity: files.identity, epochID: epoch.id, source: .microphone, sequence: committed + 1,
            payload: .settled(.init(epochID: epoch.id, source: .microphone, range: .init(samples: .init(start: Int64(committed), end: 1_000), meeting: nil), kind: .gap(.unavailable))))) == .accepted)
        for index in 0..<63 {
            let next = LiveEpoch(id: UUID(), source: index.isMultiple(of: 2) ? .system : .microphone, engineRevision: epoch.engineRevision, language: epoch.language, meetingOriginNanoseconds: nil)
            try #require(await entry.store.beginTerminalEpoch(owner: owner, epoch: next) == .accepted)
            try #require(await entry.store.admitTerminal(owner: owner, event: .init(identity: files.identity, epochID: next.id, source: next.source, sequence: 0,
                payload: .progress(.init(capturedSampleEnd: 1, admittedSampleEnd: 0, consumedSampleEnd: 0)))) == .accepted)
            try #require(await entry.store.admitTerminal(owner: owner, event: .init(identity: files.identity, epochID: next.id, source: next.source, sequence: 1,
                payload: .settled(.init(epochID: next.id, source: next.source, range: .init(samples: .init(start: 0, end: 1), meeting: nil), kind: .gap(.unavailable))))) == .accepted)
        }
        for index in 0..<769 {
            try #require(await entry.store.recordTerminalCaptureLoss(owner: owner, loss: .init(id: UUID(), source: index.isMultiple(of: 2) ? .system : .microphone, sourceEpoch: UUID(),
                frames: .init(startFrame: 0, frameCount: 1_000, sampleRate: 16_000), reason: .unavailable, bufferCount: 1)) == .accepted)
        }
        try #require(await entry.store.close(owner: files.identity) == .accepted)
        let checkpoint = await entry.store.checkpoint(); try checkpoint.validate()
        #expect(checkpoint.annotations.count == labels && checkpoint.epochs.count == 64 && checkpoint.captureLosses.count == 769)
        registry.startPersistence(files.identity); try registry.captureDidClose(files.identity); try await entry.artifacts.flush()
        let cold = LiveRecordingSessionRegistry(artifactRoot: files.root), recovered = try #require(try await cold.resolve(recordingID: files.identity.recordingID))
        #expect(await recovered.store.checkpoint() == checkpoint && recovered.artifacts.isDurable)
    }
}
