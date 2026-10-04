import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveRecordingArtifactTests {
    @Test func aClosedRevisionArrivingDuringSnapshotReturnCannotBeMarkedDurableWithOlderEvidence() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceTranscript)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, afterCheckpoint: { try? await gate.enter(.sourceTranscript) })
        let entry = try registry.register(f.identity)
        registry.startPersistence(f.identity)
        do {
            try await gate.waitForArrival()
            #expect(await entry.store.close(owner: f.identity) == .accepted)
            try registry.captureDidClose(f.identity)
            await gate.release(); try await entry.artifacts.flush()
            let recovered = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
            #expect(recovered.appTranscript?.native == (await entry.store.checkpoint()))
            #expect(recovered.appTranscript?.captureClosed == true && entry.artifacts.isDurable)
        } catch {
            await gate.release(); try? registry.retire(f.identity)
            await entry.artifacts.waitForSubmittedWrites(); throw error
        }
    }

    @Test func noWindowTerminalRevisionAfterHardwareClosureStillCheckpointsAutomatically() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root), entry = try registry.register(f.identity)
        registry.startPersistence(f.identity)
        try registry.captureDidClose(f.identity)
        // Model the actual expire() ordering: its asynchronously owned native
        // closure can return after the manager's hardware-stopped callback.
        try? await entry.artifacts.flush()
        #expect(await entry.store.close(owner: f.identity) == .accepted)
        try await f.eventually {
            let value = try? await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().appTranscript
            return value?.native == (await entry.store.checkpoint()) && value?.captureClosed == true
        }
        #expect(entry.artifacts.isDurable)
    }
    @Test func nativeRevisionObserverCoalescesHeldIOAndPersistsTheClosedFullCheckpoint() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceTranscript)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let entry = try registry.register(f.identity)
        registry.startPersistence(f.identity)
        let epoch = LiveEpoch(id: UUID(), source: .microphone, engineRevision: "fixture", language: "auto", meetingOriginNanoseconds: 0)
        #expect(await entry.store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        do {
            try await gate.waitForArrival()
            for sequence in 0..<100 {
                let event = LiveTranscriptEvent(identity: f.identity, epochID: epoch.id, source: .microphone,
                    sequence: UInt64(sequence), payload: .progress(.init(capturedSampleEnd: Int64(sequence + 1),
                        admittedSampleEnd: Int64(sequence + 1), consumedSampleEnd: Int64(sequence + 1))))
                #expect(await entry.store.admit(event) == .accepted)
            }
            let range = LiveEvidenceRange(samples: .init(start: 0, end: 100), meeting: .init(startNanoseconds: 0, endNanoseconds: 6_250_000))
            #expect(await entry.store.admit(.init(identity: f.identity, epochID: epoch.id, source: .microphone, sequence: 100,
                payload: .settled(.init(epochID: epoch.id, source: .microphone, range: range, kind: .processedSilence)))) == .accepted)
            #expect(await entry.store.close(owner: f.identity) == .accepted)
            try registry.captureDidClose(f.identity)
            #expect(entry.artifacts.pendingIntervals == 1)
            #expect(await entry.artifacts.writer.status().admittedWriteWaiters == 1)
            await gate.release(); try await entry.artifacts.flush()
            let restored = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
            #expect(restored.appTranscript?.captureClosed == true)
            #expect(restored.appTranscript?.native == (await entry.store.checkpoint()))
        } catch {
            await gate.release(); try? registry.retire(f.identity)
            await entry.artifacts.waitForSubmittedWrites(); throw error
        }
    }

    @Test func retiringAHeldPayloadDoesNotReturnItsReservationBeforeTheWriteActuallyReturns() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceTranscript)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1, beforeStage: { try await gate.enter($0) })
        var entry: LiveRecordingSessionRegistry.Entry? = try registry.registerLegacy(f.identity)
        registry.startPersistence(f.identity)
        var flush: Task<Void, Error>?
        do {
            flush = Task { [owner = try #require(entry).artifacts] in try await owner.flush() }
            try await gate.waitForArrival()
            try registry.retire(f.identity); entry = nil
            let next = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { _ = try registry.registerLegacy(next) }
            await gate.release()
            await #expect(throws: (any Error).self) { try await flush?.value }
            flush = nil
            try await f.eventually { await MainActor.run { (try? registry.registerLegacy(next)) != nil } }
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("live-transcript.json").path))
        } catch {
            await gate.release(); try? registry.retire(f.identity); try? await flush?.value
            throw error
        }
    }

    @Test func legacyIDsAndUnqualifiedEvidenceSurviveCloseAndRestartWithoutAWindow() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let entry = try registry.registerLegacy(f.identity)
        registry.startPersistence(f.identity)
        let segment = LiveTranscriptSegment(start: 1, end: 2, text: "Kept without a window", speaker: "You")
        try entry.artifacts.appendLegacy([segment])
        try registry.captureDidClose(f.identity)
        try await entry.artifacts.flush()
        let restored = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
        let artifact = try #require(restored.appTranscript)
        #expect(artifact.legacy?.first?.id == segment.id)
        let context = try artifact.legacyContext()
        #expect(context.segments.first?.text == segment.text)
        #expect(context.segments.first?.meeting == nil && context.segments.first?.finalPlayback == nil)
        #expect(context.source.cutoffNanoseconds == nil && context.source.liveMetadata == nil)
        #expect(context.source.speakerLegend.first?.displayName == "You")
    }

    @Test func failedCheckpointRetainsTheNewestValueAndRetryBindsWithoutAWindow() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let fault = LiveArtifactFault(stage: .sourceTranscript)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await fault.check($0) })
        let entry = try registry.registerLegacy(f.identity)
        registry.startPersistence(f.identity)
        try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "First")])
        await #expect(throws: (any Error).self) { try await entry.artifacts.flush() }
        #expect(entry.artifacts.failure != nil && !entry.artifacts.isDurable)
        try entry.artifacts.appendLegacy([.init(start: 1, end: 2, text: "Newest")])
        try registry.captureDidClose(f.identity)
        try entry.artifacts.retry()
        try entry.artifacts.bind(to: f.audio)
        try await entry.artifacts.flush()
        let recovered = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
        #expect(recovered.audioURL == f.audio)
        #expect(recovered.appTranscript?.legacy?.map(\.text) == ["First", "Newest"])
        #expect(entry.artifacts.isDurable && entry.artifacts.failure == nil)
    }

    @Test func saturatedPinnedOrDirtyOwnersDeferAdmissionAndOnlyDurableClosedOwnersEvict() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 2)
        var first: LiveRecordingSessionRegistry.Entry? = try registry.registerLegacy(f.identity)
        registry.startPersistence(f.identity)
        let secondID = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        _ = try registry.registerLegacy(secondID)
        let thirdID = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { try registry.registerLegacy(thirdID) }
        #expect(registry.reservedPayloadBytes == 2 * LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
        try registry.captureDidClose(f.identity)
        var pin = first?.artifacts.pin()
        try await first?.artifacts.flush()
        #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { try registry.registerLegacy(thirdID) }
        pin?.release(); pin = nil; first = nil
        try await f.eventually { await MainActor.run { (try? registry.registerLegacy(thirdID)) != nil } }
        #expect(registry.entry(identity: f.identity) == nil && !registry.isRetired(recordingID: f.identity.recordingID))
        let provider = TranscriptContextProvider.recording(recordingID: f.identity.recordingID, registry: registry,
            legacy: { .legacy(text: "Wrong fallback", recordingID: f.identity.recordingID, speakerLabels: []) })
        await #expect(throws: (any Error).self) { _ = try await provider.freeze().snapshot() }
        #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().appTranscript != nil)
    }

    @Test func nativeGrowthIsRejectedBeforeHistoryAccumulatesAndTerminalGapStillCloses() async throws {
        let f = LiveTranscriptFixture(), epoch = f.epoch()
        let store = LiveTranscriptStore(identity: f.identity, retainedEvidenceLimit: 64_000)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(2))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1, "Kept")))) == .accepted)
        let before = await store.checkpoint()
        #expect(await store.admit(f.event(epoch, 2, .committed(f.segment(epoch, 1, 1, 2, String(repeating: "x", count: 10_000))))) == .rejected(.capacity))
        #expect(await store.checkpoint() == before)
        #expect(await store.admit(f.event(epoch, 2, f.settlement(epoch, 1, 2, .gap(.unavailable)))) == .accepted)
        #expect(await store.close(owner: f.identity) == .accepted)
        try await store.checkpoint().validate()
        #expect(await store.retainedEvidenceBytes <= 64_000)
    }
}

@Suite struct LiveTranscriptArtifactSchemaTests {
    @MainActor @Test func fullOwnedTerminalInventoryFitsReservedEvidenceAndTheDurableEnvelopeAfterNormalGrowthRetires() async throws {
        let fixture = try LiveArtifactFixture(); defer { fixture.remove() }
        let identity = fixture.identity, owner = UUID()
        let store = LiveTranscriptStore(identity: identity, retainedEvidenceLimit: LiveRecordingArtifactOwner.evidenceLimit)
        try #require(store.bindCaptureOwner(owner, accepting: { true }))
        let first = LiveEpoch(id: UUID(), source: .microphone, engineRevision: String(repeating: "r", count: 256),
            language: String(repeating: "l", count: 32), meetingOriginNanoseconds: nil)
        try #require(await store.beginEpoch(owner: identity, epoch: first) == .accepted)
        try #require(await store.admit(.init(identity: identity, epochID: first.id, source: first.source, sequence: 0,
            payload: .progress(.init(capturedSampleEnd: 1_000, admittedSampleEnd: 1_000, consumedSampleEnd: 1_000)))) == .accepted)
        var count: UInt64 = 0
        for index in 0..<16 {
            let result = await store.admit(.init(identity: identity, epochID: first.id, source: first.source, sequence: UInt64(index + 1),
                payload: .committed(.init(id: .init(epochID: first.id, index: UInt64(index)), source: first.source,
                    range: .init(samples: .init(start: Int64(index), end: Int64(index + 1)), meeting: nil), text: String(repeating: "x", count: 10_000)))))
            if result == .rejected(.capacity) { break }
            try #require(result == .accepted); count += 1
        }
        try #require(await store.evidenceGrowthRetired && count > 0)
        try #require(await store.admitTerminal(owner: owner, event: .init(identity: identity, epochID: first.id, source: first.source, sequence: count + 1,
            payload: .settled(.init(epochID: first.id, source: first.source,
                range: .init(samples: .init(start: Int64(count), end: 1_000), meeting: nil), kind: .gap(.unavailable))))) == .accepted)
        for index in 0..<63 {
            let epoch = LiveEpoch(id: UUID(), source: index.isMultiple(of: 2) ? .system : .microphone,
                engineRevision: first.engineRevision, language: first.language, meetingOriginNanoseconds: nil)
            try #require(await store.beginTerminalEpoch(owner: owner, epoch: epoch) == .accepted)
            try #require(await store.admitTerminal(owner: owner, event: .init(identity: identity, epochID: epoch.id, source: epoch.source, sequence: 0,
                payload: .progress(.init(capturedSampleEnd: 1, admittedSampleEnd: 0, consumedSampleEnd: 0)))) == .accepted)
            try #require(await store.admitTerminal(owner: owner, event: .init(identity: identity, epochID: epoch.id, source: epoch.source, sequence: 1,
                payload: .settled(.init(epochID: epoch.id, source: epoch.source,
                    range: .init(samples: .init(start: 0, end: 1), meeting: nil), kind: .gap(.unavailable))))) == .accepted)
        }
        for index in 0..<(512 + 256 + 1) {
            try #require(await store.recordTerminalCaptureLoss(owner: owner, loss: .init(id: UUID(),
                source: index.isMultiple(of: 2) ? .microphone : .system, sourceEpoch: UUID(),
                frames: .init(startFrame: 0, frameCount: 1_000, sampleRate: 16_000), reason: .unavailable, bufferCount: 1)) == .accepted)
        }
        try #require(await store.close(owner: identity) == .accepted)
        let checkpoint = await store.checkpoint(); try checkpoint.validate()
        #expect(checkpoint.captureLosses.count == 769 && checkpoint.epochs.count == 64)
        #expect(checkpoint.coverage.filter { $0.kind == .gap(.unavailable) }.count == 64)
        let artifact = LiveTranscriptArtifact(identity: identity, revision: checkpoint.revision + 1, native: checkpoint, captureClosed: true)
        let bytes = try LiveArtifactEncoding.encode(artifact, limit: 3 * 1_024 * 1_024)
        #expect(try LiveTranscriptArtifactCodec.decode(bytes).app == artifact)
        let writer = LiveSessionArtifactStore(identity: identity, rootURL: fixture.root)
        try await writer.saveTranscript(artifact)
        let registry = LiveRecordingSessionRegistry(artifactRoot: fixture.root)
        let restored = try #require(try await registry.resolve(recordingID: identity.recordingID))
        #expect(await restored.store.checkpoint() == checkpoint)
        #expect(restored.artifacts.isDurable && restored.artifacts.acceptedRevision == artifact.revision)
        try await restored.artifacts.flush()
        try restored.artifacts.bind(to: fixture.audio); try await restored.artifacts.flush()
        let bound = try LiveTranscriptArtifactCodec.decode(Data(contentsOf: fixture.audio.deletingPathExtension().appendingPathExtension("live-transcript.json")))
        #expect(try bound.encoded(generation: nil, limit: 3 * 1_024 * 1_024) == bytes)
    }
    @Test func finalRawTextAndStableRichIDsRoundTripWithoutInventedClocks() throws {
        let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let id = UUID(), publication = LiveAppFinalPublication(id: id, revision: 1,
            transcript: .init(segments: []), fallbackText: "A complete text-only result")
        let artifact = LiveTranscriptArtifact(identity: identity, revision: 1, legacy: [], captureClosed: true, finalPublication: publication)
        let decoded = try LiveTranscriptArtifactCodec.decode(LiveArtifactEncoding.encode(artifact, limit: 1_048_576))
        #expect(decoded.app?.finalPublication == publication)
        let context = try #require(decoded.app?.finalContext())
        #expect(context.source.publicationID == id && context.source.scope == .completeFinal)
        #expect(context.segments.first?.text == "A complete text-only result")
        #expect(context.segments.first?.finalPlayback == nil && context.segments.first?.meeting == nil)
        let segment = RichSegment(start: 0, end: 1, text: "Saved", originalText: "Saved", speakerId: "speaker")
        let rich = LiveAppFinalPublication(id: UUID(), revision: 2,
            transcript: .init(segments: [segment], speakerLabels: [.init(id: "speaker", displayName: "Reviewed")]))
        #expect(rich.context(identity: identity).segments.first?.id == segment.id.uuidString.lowercased())
        #expect(rich.context(identity: identity).source.speakerLegend.first?.displayName == "Reviewed")
        let unqualified = LiveAppFinalPublication(id: UUID(), revision: 3,
            transcript: .init(segments: [.init(start: -1, end: 0, text: "No known timing", originalText: "No known timing")]))
        try unqualified.validate()
        #expect(unqualified.context(identity: identity).segments.first?.finalPlayback == nil)
    }

    @Test func versionOneCanonicalBindingSurvivesMigrationAndNewEnvelopeRejectsMixedOwners() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        let native = await LiveTranscriptStore(identity: f.identity).checkpoint()
        try await writer.saveTranscript(native)
        try await writer.bind(to: f.audio)
        #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().transcript == native)
        await #expect(throws: LiveArtifactError.revisionConflict) {
            try await writer.saveTranscript(LiveTranscriptArtifact(identity: f.identity, revision: native.revision, native: native))
        }
        let new = LiveTranscriptArtifact(identity: f.identity, revision: native.revision + 1, native: native)
        try await writer.saveTranscript(new)
        #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().appTranscript == new)
        let foreign = LiveTranscriptArtifact(identity: .init(recordingID: UUID(), captureSessionID: UUID()), revision: 2, native: native)
        #expect(throws: (any Error).self) { try foreign.validate() }
        let mixed = LiveTranscriptArtifact(identity: f.identity, revision: 2, native: native, legacy: [])
        #expect(throws: (any Error).self) { try mixed.validate() }
    }
}
