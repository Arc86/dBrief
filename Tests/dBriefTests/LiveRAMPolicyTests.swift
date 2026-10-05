import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveRAMPolicyTests {
    private func provider(_ f: LiveArtifactFixture, _ registry: LiveRecordingSessionRegistry) -> TranscriptContextProvider {
        .recording(recordingID: f.identity.recordingID, registry: registry,
            legacy: { .legacy(text: "Wrong fallback", recordingID: f.identity.recordingID, speakerLabels: []) })
    }
    private func expectEmptyWriter(_ owner: LiveRecordingArtifactOwner) async {
        let status = await owner.writer.status()
        #expect(status.acceptedTranscriptRevision == 0 && status.durableTranscriptRevision == 0)
        #expect(status.acceptedChatRevision == 0 && status.durableChatRevision == 0)
        #expect(status.admittedWriteWaiters == 0 && status.admittedControls == 0)
        #expect(status.queuedEncodedBytes == 0 && status.retainedPayloads == 0)
        #expect(status.audioURL == nil && status.failure == nil && !status.deleted)
        #expect(!owner.persistenceStarted && owner.pendingIntervals == 0)
        #expect(!owner.isDurable && !owner.canEvict && !owner.isRecoveredOwner)
        #expect(owner.durableRevision == 0 && owner.durableChatRevision == 0)
    }

    @Test func RAMConstructorCannotAdoptThePersistenceAuthorityOfASuppliedWriter() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let budget = LiveRecordingPayloadBudget(ownerLimit: 1), lease = try budget.reserve()
        let externalValidity = RecordingDerivativeValidity(), externalCalls = RAMPolicyCalls()
        let supplied = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root,
            validity: externalValidity, payloadReservation: lease, beforeStage: { externalCalls.record($0) })
        try await supplied.saveTranscript(.init(identity: f.identity, revision: 1, legacy: [], captureClosed: true))
        let sentinel = f.session.appendingPathComponent("foreign-sentinel")
        try Data("Unowned original bytes".utf8).write(to: sentinel)
        let files = [f.audio, f.audio.deletingPathExtension().appendingPathExtension("json"),
            f.session.appendingPathComponent("live-transcript.json"), sentinel]
        let originalBytes = try files.map { try Data(contentsOf: $0) }
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        let sessionNames = try FileManager.default.contentsOfDirectory(atPath: f.session.path).sorted()
        let before = await supplied.status(), originalStages = externalCalls.values
        let ordinary = LiveRecordingArtifactOwner(identity: f.identity,
            store: LiveTranscriptStore(identity: f.identity, validity: externalValidity, payloadReservation: lease),
            validity: externalValidity, native: false, rootURL: f.root, payloadReservation: lease,
            beforeStage: { externalCalls.record($0) }, recoveredWriter: supplied)
        #expect(ordinary.capturePersistenceAllowed && ordinary.writer === supplied)
        let validity = RecordingDerivativeValidity(), calls = RAMPolicyCalls()
        let owner = LiveRecordingArtifactOwner(identity: f.identity,
            store: LiveTranscriptStore(identity: f.identity, validity: validity, payloadReservation: lease),
            validity: validity, native: false, rootURL: f.root, payloadReservation: lease,
            capturePersistenceAllowed: false, beforeStage: { calls.record($0) }, recoveredWriter: supplied)
        #expect(!owner.capturePersistenceAllowed && owner.writer !== supplied)
        #expect(budget.reservedBytes == LiveRecordingArtifactOwner.reservationBytes)
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.saveTranscript(.init(identity: f.identity, revision: 2, legacy: [], captureClosed: true)) }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.saveChat(f.history("Direct false writer"), revision: 1) }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.clearChat(revision: 2) }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await owner.writer.recover() }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.bind(to: f.audio) }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.retry() }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await owner.writer.commitDeletionIntent() }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await owner.writer.inspectForExport() }
        owner.start()
        try owner.appendLegacy([.init(start: 0, end: 1, text: "RAM constructor source")])
        let frozen = try owner.legacyContext(); owner.closeCapture()
        try owner.bind(to: f.audio); try owner.retry(); try await owner.flush()
        try owner.publishFinal(.init(text: "RAM final"))
        #expect(frozen.segments.first?.text == "RAM constructor source")
        #expect(try owner.finalContext()?.segments.first?.text == "RAM final")
        #expect(owner.acceptedRevision == 3 && owner.admittedAudioURL == f.audio)
        #expect(try await owner.loadChat() == nil)
        #expect(throws: LiveArtifactError.missingEvidence) { _ = try owner.saveChat(f.history("RAM history"), urgent: true) }
        #expect(throws: LiveArtifactError.missingEvidence) { _ = try owner.clearChat() }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await owner.commitDeletionIntent() }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.flushAdmittedWrites() }
        await expectEmptyWriter(owner)
        let after = await supplied.status()
        #expect(after.acceptedTranscriptRevision == before.acceptedTranscriptRevision)
        #expect(after.durableTranscriptRevision == before.durableTranscriptRevision)
        #expect(after.acceptedChatRevision == before.acceptedChatRevision && after.durableChatRevision == before.durableChatRevision)
        #expect(after.admittedWriteWaiters == before.admittedWriteWaiters && after.admittedControls == before.admittedControls)
        #expect(after.queuedEncodedBytes == before.queuedEncodedBytes && after.retainedPayloads == before.retainedPayloads)
        #expect(after.audioURL == before.audioURL && after.failure == before.failure && after.deleted == before.deleted)
        #expect(externalCalls.values == originalStages && calls.values.isEmpty)
        #expect(try externalValidity.withValidResult { true })
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted() == rootNames)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.session.path).sorted() == sessionNames)
        for (file, bytes) in zip(files, originalBytes) { #expect(try Data(contentsOf: file) == bytes) }
        #expect(budget.reservedBytes == LiveRecordingArtifactOwner.reservationBytes)
    }

    @Test func RAMRevisionsAndFrozenFactsSurviveEveryLifecycleCallWithoutArtifactWork() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let calls = RAMPolicyCalls()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { calls.record($0) })
        let entry = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false), owner = entry.artifacts
        #expect(!owner.capturePersistenceAllowed)
        registry.startPersistence(f.identity)
        #expect(owner.acceptedRevision == 0)
        let segment = LiveTranscriptSegment(start: 0, end: 1, text: "Original committed source", speaker: "You")
        try owner.appendLegacy([segment]); let first = try owner.legacyContext()
        #expect(owner.acceptedRevision == 1 && first.segments.first?.text == segment.text)
        try owner.appendLegacy([segment]); #expect(owner.acceptedRevision == 1)
        try owner.appendLegacy([.init(start: 1, end: 2, text: "Second committed source")])
        #expect(try first.segments.count == 1 && owner.legacyContext().segments.count == 2)
        #expect(try owner.legacyContext().segments.first?.id == first.segments.first?.id)
        try registry.captureDidClose(f.identity); #expect(owner.acceptedRevision == 3)
        try owner.bind(to: f.audio); try owner.retry(); try await owner.flush()
        #expect(owner.admittedAudioURL == f.audio && owner.acceptedRevision == 3)
        try owner.publishFinal(.init(text: "Raw final"))
        let raw = try #require(try owner.finalContext()); let rawRevision = owner.acceptedRevision
        try owner.publishFinal(.init(text: "Must not replace saved facts"))
        #expect(owner.acceptedRevision == rawRevision)
        let rich = RichTranscript(segments: [.init(start: 0, end: 1, text: "Saved rich", originalText: "Saved rich", speakerId: "s")],
            speakerLabels: [.init(id: "s", displayName: "Speaker")])
        try owner.publishSavedFinal(rich); let saved = try #require(try owner.finalContext())
        let savedRevision = owner.acceptedRevision
        try owner.publishSavedFinal(rich); #expect(owner.acceptedRevision == savedRevision)
        #expect(raw.segments.first?.text == "Raw final" && saved.segments.first?.text == "Saved rich")
        #expect(saved.source.publicationID == raw.source.publicationID && saved.source.publicationRevision == 2)
        #expect(first.segments.first?.text == segment.text)
        try owner.retry(); try await owner.flush(); await expectEmptyWriter(owner)
        #expect(calls.values.isEmpty && !FileManager.default.fileExists(atPath: f.session.path))
        #expect(try String(contentsOf: f.audio, encoding: .utf8) == "Model-free media ownership fixture")
        let cold = LiveRecordingSessionRegistry(artifactRoot: f.root)
        #expect(try await cold.resolve(recordingID: f.identity.recordingID) == nil)
    }

    @Test func RAMRegistrationAndAssociationLeaveOpaqueArtifactNamespacesUntouched() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let sentinel = Data("Unknown foreign artifact bytes".utf8)
        try FileManager.default.createDirectory(at: f.session, withIntermediateDirectories: true)
        let foreign = f.session.appendingPathComponent("live-transcript.json")
        try sentinel.write(to: foreign)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let entry = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false)
        registry.startPersistence(f.identity); try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "RAM only")])
        try registry.captureDidClose(f.identity); try entry.artifacts.bind(to: f.audio); try await entry.artifacts.flush()
        #expect(try Data(contentsOf: foreign) == sentinel)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.session.path) == ["live-transcript.json"])
        let link = f.root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.session)
        let linked = LiveRecordingSessionRegistry(artifactRoot: link)
        let other = try linked.registerLegacy(f.identity, capturePersistenceAllowed: false)
        linked.startPersistence(f.identity); try linked.captureDidClose(f.identity)
        try other.artifacts.bind(to: f.audio); try other.artifacts.retry(); try await other.artifacts.flush()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == f.session.path)
        #expect(try Data(contentsOf: foreign) == sentinel)
        await expectEmptyWriter(entry.artifacts); await expectEmptyWriter(other.artifacts)
    }

    @Test func RAMBindRequiresTheActualMasterAndCannotChangeAnAdmittedAssociation() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let owner = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false).artifacts
        try registry.captureDidClose(f.identity)
        let metadata = f.audio.deletingPathExtension().appendingPathExtension("json")
        let original = try Data(contentsOf: metadata)
        try JSONEncoder().encode(RecordingMetadataPayload(recordingID: UUID(), dateISO8601: "fixture", durationSeconds: 1,
            meetingTitle: "foreign", masterFileName: f.audio.lastPathComponent, segmentFileNames: [], warnings: [])).write(to: metadata)
        #expect(throws: LiveArtifactError.wrongOwner) { try owner.bind(to: f.audio) }
        #expect(owner.admittedAudioURL == nil)
        try JSONEncoder().encode(RecordingMetadataPayload(recordingID: f.identity.recordingID, dateISO8601: "fixture", durationSeconds: 1,
            meetingTitle: "wrong filename", masterFileName: "different.wav", segmentFileNames: [], warnings: [])).write(to: metadata)
        #expect(throws: LiveArtifactError.wrongOwner) { try owner.bind(to: f.audio) }
        #expect(owner.admittedAudioURL == nil)
        try original.write(to: metadata)
        let heldAudio = f.root.appendingPathComponent("original-held.wav")
        try FileManager.default.moveItem(at: f.audio, to: heldAudio)
        #expect(throws: LiveArtifactError.wrongOwner) { try owner.bind(to: f.audio) }
        try FileManager.default.createSymbolicLink(at: f.audio, withDestinationURL: heldAudio)
        #expect(throws: LiveArtifactError.unsafePath) { try owner.bind(to: f.audio) }
        try FileManager.default.removeItem(at: f.audio); try FileManager.default.moveItem(at: heldAudio, to: f.audio)
        try owner.bind(to: f.audio); try owner.bind(to: f.audio)
        let second = f.root.appendingPathComponent("second.wav")
        try Data("Other master".utf8).write(to: second)
        try JSONEncoder().encode(RecordingMetadataPayload(recordingID: f.identity.recordingID, dateISO8601: "fixture", durationSeconds: 1,
            meetingTitle: "second", masterFileName: second.lastPathComponent, segmentFileNames: [], warnings: [])).write(to: second.deletingPathExtension().appendingPathExtension("json"))
        #expect(throws: LiveArtifactError.wrongOwner) { try owner.bind(to: second) }
        #expect(owner.admittedAudioURL == f.audio && owner.acceptedRevision == 1)
        await expectEmptyWriter(owner)
    }

    @Test func RAMPolicyAndNativeKindCannotBeChangedByDuplicateRegistration() throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let entry = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false)
        #expect(try registry.registerLegacy(f.identity, capturePersistenceAllowed: false) === entry)
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { _ = try registry.registerLegacy(f.identity) }
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { _ = try registry.register(f.identity) }
        let alias = LiveSessionIdentity(recordingID: UUID(), captureSessionID: f.identity.captureSessionID)
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { _ = try registry.registerLegacy(alias, capturePersistenceAllowed: false) }
        let durableID = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let durable = try registry.registerLegacy(durableID)
        #expect(durable.artifacts.capturePersistenceAllowed)
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { _ = try registry.registerLegacy(durableID, capturePersistenceAllowed: false) }
        try registry.retire(f.identity)
        #expect(throws: LiveRecordingSessionRegistry.Failure.retired) { _ = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false) }
    }

    @Test(arguments: [false, true]) func diskDiscoveryCannotOverwriteResidentRAMPolicyOrPartiallyMerge(alias: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let diskID = alias ? LiveSessionIdentity(recordingID: UUID(), captureSessionID: f.identity.captureSessionID) : f.identity
        let writer = LiveSessionArtifactStore(identity: diskID, rootURL: f.root)
        try await writer.saveTranscript(.init(identity: diskID, revision: 1, legacy: [], captureClosed: true))
        let unrelated = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let otherWriter = LiveSessionArtifactStore(identity: unrelated, rootURL: f.root)
        try await otherWriter.saveTranscript(.init(identity: unrelated, revision: 1, legacy: [], captureClosed: true))
        let source = f.session.appendingPathComponent("live-transcript.json"), bytes = try Data(contentsOf: source)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let ram = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false)
        await #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { try await registry.discover() }
        #expect(registry.entry(identity: f.identity) === ram && !ram.artifacts.capturePersistenceAllowed)
        #expect(registry.retentionHints.count == 1 && !registry.owns(recordingID: unrelated.recordingID))
        #expect(try Data(contentsOf: source) == bytes)
        await expectEmptyWriter(ram.artifacts)
    }

    @Test func RAMArtifactControlsAndExportRejectBeforePinsReservationsOrInspection() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let calls = RAMPolicyCalls()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { calls.record($0) })
        let owner = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false).artifacts
        try registry.captureDidClose(f.identity)
        #expect(owner.canExpire)
        #expect(try await owner.loadChat() == nil)
        let service = TranscriptChatService(contextProvider: provider(f, registry), appSettings: AppSettings(), localPlugin: nil)
        #expect(!owner.attachChatService(service))
        #expect(throws: LiveArtifactError.missingEvidence) { _ = try owner.saveChat(f.history("No artifact history"), urgent: true) }
        #expect(throws: LiveArtifactError.missingEvidence) { _ = try owner.clearChat() }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await owner.commitDeletionIntent() }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.flushAdmittedWrites() }
        #expect(throws: LiveArtifactError.missingEvidence) { try owner.hydrate(.init(chat: nil, transcriptValue: nil, audioURL: nil, deleted: false)) }
        let reserved = registry.reservedPayloadBytes
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await registry.prepareHistoryExport(recordingID: f.identity.recordingID, audioURL: f.audio) }
        #expect(registry.reservedPayloadBytes == reserved && owner.canExpire && calls.values.isEmpty)
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.saveChat(f.history("Direct"), revision: 1) }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.clearChat(revision: 1) }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.saveTranscript(.init(identity: f.identity, revision: 1, legacy: [], captureClosed: true)) }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await owner.writer.recover() }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.bind(to: f.audio) }
        await #expect(throws: LiveArtifactError.missingEvidence) { try await owner.writer.retry() }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await owner.writer.commitDeletionIntent() }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await owner.writer.inspectForExport() }
        #expect(calls.values.isEmpty && !FileManager.default.fileExists(atPath: f.session.path))
        await expectEmptyWriter(owner)
    }

    @Test func RAMPressureRejectsWholeBatchesAndOnlyClosureAdvancesAfterStickyRetirement() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let owner = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false).artifacts
        let kept = LiveTranscriptSegment(start: 0, end: 1, text: "Exact prefix")
        try owner.appendLegacy([kept]); let before = try owner.legacyContext(), revision = owner.acceptedRevision
        let excessive = (0..<32).map { LiveTranscriptSegment(start: Double($0), end: Double($0 + 1), text: String(repeating: "x", count: 65_536)) }
        #expect(throws: LiveArtifactError.artifactTooLarge) { try owner.appendLegacy(excessive) }
        #expect(owner.growthRetired && owner.acceptedRevision == revision)
        #expect(try owner.legacyContext() == before)
        #expect(throws: LiveArtifactError.deleted) { try owner.appendLegacy([.init(start: 1, end: 2, text: "Late")]) }
        try registry.captureDidClose(f.identity); #expect(owner.acceptedRevision == revision + 1)
        try owner.publishFinal(.init(text: "Bounded final")); let final = try #require(try owner.finalContext())
        let finalRevision = owner.acceptedRevision
        let rich = RichTranscript(segments: [.init(start: 0, end: 1, text: String(repeating: "x", count: 100_000), originalText: "")])
        #expect(throws: LiveArtifactError.artifactTooLarge) { try owner.publishSavedFinal(rich) }
        #expect(try owner.finalContext() == final && owner.acceptedRevision == finalRevision)
        try await owner.flush(); await expectEmptyWriter(owner)
    }

    @Test func sharedBudgetDoesNotEvictClosedRAMOwnersToFitAFourthFullOwner() throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        for _ in 0..<3 {
            let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
            let entry = try registry.registerLegacy(identity, capturePersistenceAllowed: false)
            try registry.captureDidClose(identity); #expect(entry.artifacts.canExpire && !entry.artifacts.canEvict)
        }
        #expect(registry.reservedPayloadBytes == 3 * LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
        #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) {
            _ = try registry.registerLegacy(.init(recordingID: UUID(), captureSessionID: UUID()), capturePersistenceAllowed: false)
        }
        #expect(registry.reservedPayloadBytes == 3 * LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
    }

    @Test func cancelledActualCallbackRetainsRetiredRAMSourceUntilItsOriginalReturn() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var entry: LiveRecordingSessionRegistry.Entry? = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false)
        try entry?.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Held original facts")])
        var snapshot: TranscriptContextSnapshot? = try entry?.artifacts.legacyContext()
        let gate = LiveArtifactGate(stage: .sourceTranscript)
        var callback: Task<String?, Error>? = Task { [value = try #require(snapshot)] in
            defer { withExtendedLifetime(value) {} }
            try await gate.enter(.sourceTranscript)
            return value.segments.first?.text
        }
        snapshot = nil
        do {
            try await gate.waitForArrival(); callback?.cancel()
            try registry.retire(f.identity); entry = nil
            let next = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { _ = try registry.registerLegacy(next, capturePersistenceAllowed: false) }
            await gate.release(); #expect(try await callback?.value == "Held original facts"); callback = nil
            try await f.eventually { await MainActor.run { registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes } }
            _ = try registry.registerLegacy(next, capturePersistenceAllowed: false)
        } catch { await gate.release(); _ = try? await callback?.value; throw error }
    }

    @Test func QuitSealsRAMAdmissionWithoutAnArtifactTargetOrRevokingFrozenFacts() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let calls = RAMPolicyCalls()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { calls.record($0) })
        let entry = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false), owner = entry.artifacts
        try owner.appendLegacy([.init(start: 0, end: 1, text: "Frozen at Quit")]); try registry.captureDidClose(f.identity)
        try owner.publishFinal(.init(text: "Final at Quit"))
        let frozen = provider(f, registry).freeze()
        let snapshot = try await frozen.snapshot(), reservation = registry.reservedPayloadBytes
        let target = registry.freezeForTermination()
        #expect(target.owners.isEmpty && target.loads.isEmpty)
        #expect(throws: LiveArtifactError.terminating) { _ = try owner.legacyContext() }
        #expect(throws: LiveArtifactError.terminating) { _ = try owner.finalContext() }
        #expect(throws: LiveArtifactError.terminating) { _ = try provider(f, registry).freezeForChat(attachedOwner: nil) }
        await #expect(throws: LiveArtifactError.terminating) { _ = try await provider(f, registry).freeze().snapshot() }
        #expect(try await frozen.snapshot() == snapshot)
        try snapshot.contextOwnership?.requireValid()
        #expect(registry.reservedPayloadBytes == reservation && calls.values.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.session.path))
        await expectEmptyWriter(owner)
    }

    @Test func QuitSealsAnActualPrivateRAMCandidateWhileItsHydrationCallbackIsHeld() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let calls = RAMPolicyCalls(), probe = RAMCandidateProbe(), gate = LiveArtifactGate(stage: .ownerHydration)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 2, beforeStage: { calls.record($0) })
        var original: LiveRecordingSessionRegistry.Entry? = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false)
        try registry.captureDidClose(f.identity); try original?.artifacts.bind(to: f.audio)
        let phase = try registry.beginReplacement(recordingID: f.identity.recordingID, audioURL: f.audio)
        try registry.adoptReplacement(phase, attemptID: UUID()); original = nil
        registry.onHydration = { entry in
            try entry.artifacts.publishFinal(.init(text: "Actual private candidate"))
            let value = try #require(try entry.artifacts.finalContext())
            defer { withExtendedLifetime(value) {} }
            probe.entry = entry; probe.frozen = TranscriptContextProvider.value { value }.freeze()
            try await gate.enter(.ownerHydration)
            try value.contextOwnership?.requireValid()
            probe.returned = true
        }
        var operation: Task<LiveRecordingSessionRegistry.Entry?, Error>? = Task { try await registry.finishReplacement(phase) }
        do {
            try await gate.waitForArrival()
            var frozen = probe.frozen
            #expect(registry.entry(recordingID: f.identity.recordingID) == nil)
            let targets = registry.freezeForTermination(); operation?.cancel()
            #expect(targets.owners.isEmpty && targets.loads.isEmpty)
            #expect(throws: LiveArtifactError.terminating) { _ = try #require(probe.entry).artifacts.legacyContext() }
            #expect(throws: LiveArtifactError.terminating) { _ = try #require(probe.entry).artifacts.finalContext() }
            #expect(throws: LiveArtifactError.terminating) { _ = try #require(probe.entry).artifacts.beginChatRequest() }
            var old = try await frozen?.snapshot()
            #expect(old?.segments.first?.text == "Actual private candidate")
            try old?.contextOwnership?.requireValid()
            probe.entry = nil; probe.frozen = nil; frozen = nil
            #expect(!probe.returned && calls.values.isEmpty)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await gate.release()
            await #expect(throws: LiveArtifactError.terminating) { _ = try await operation?.value }
            operation = nil
            #expect(probe.returned && registry.entry(recordingID: f.identity.recordingID) == nil)
            #expect(throws: CancellationError.self) { try old?.contextOwnership?.requireValid() }
            old = nil
            try await f.eventually { await MainActor.run { registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes } }
            #expect(calls.values.isEmpty && !FileManager.default.fileExists(atPath: f.session.path))
        } catch { await gate.release(); _ = try? await operation?.value; throw error }
    }

    @Test func explicitReplacementPreservesRAMPolicyAndFreshValidityAcrossDiskCollision() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let original = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false)
        try original.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Captured old source")])
        try registry.captureDidClose(f.identity); try original.artifacts.bind(to: f.audio)
        let old = try original.artifacts.legacyContext(), oldValidity = original.validity
        let phase = try registry.beginReplacement(recordingID: f.identity.recordingID, audioURL: f.audio)
        #expect(throws: LiveArtifactError.deleted) { _ = try original.artifacts.legacyContext() }
        #expect(throws: LiveArtifactError.deleted) { _ = try original.artifacts.finalContext() }
        try registry.adoptReplacement(phase, attemptID: UUID())
        #expect(throws: CancellationError.self) { try old.contextOwnership?.requireValid() }
        let disk = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await disk.saveTranscript(.init(identity: f.identity, revision: 1, legacy: [], captureClosed: true))
        let source = f.session.appendingPathComponent("live-transcript.json"), bytes = try Data(contentsOf: source)
        await #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { try await registry.discover() }
        registry.onHydration = { entry in try entry.artifacts.publishFinal(.init(text: "New explicitly reprocessed final")) }
        let replacement = try #require(try await registry.finishReplacement(phase))
        #expect(replacement.validity !== oldValidity && !replacement.artifacts.capturePersistenceAllowed)
        #expect(replacement.artifacts.isNonpersistingFinalOnly && !replacement.artifacts.isDurable)
        #expect(try replacement.artifacts.finalContext()?.segments.first?.text == "New explicitly reprocessed final")
        #expect(throws: LiveArtifactError.missingEvidence) { _ = try replacement.artifacts.legacyContext() }
        await expectEmptyWriter(replacement.artifacts)
        #expect(try Data(contentsOf: source) == bytes)
    }
}

private final class RAMPolicyCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [LiveArtifactStage] = []
    func record(_ stage: LiveArtifactStage) { lock.withLock { stages.append(stage) } }
    var values: [LiveArtifactStage] { lock.withLock { stages } }
}

@MainActor private final class RAMCandidateProbe {
    var entry: LiveRecordingSessionRegistry.Entry?
    var frozen: TranscriptContextProvider.Frozen?
    var returned = false
}
