import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveRecordingReloadTests {
    @Test func discoveredDeletionInvalidatesTheResidentProviderWithoutGrantingCleanupAuthority() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveTranscript(LiveTranscriptArtifact(identity: f.identity, revision: 1,
            legacy: [.init(.init(start: 0, end: 1, text: "Previously saved evidence"))], captureClosed: true))
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let loaded = try #require(try await registry.resolve(recordingID: f.identity.recordingID))
        let unrelatedID = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let unrelated = try registry.registerLegacy(unrelatedID)
        var removed: [UUID] = []
        registry.onEviction = { removed.append($0.identity.recordingID) }
        let provider = TranscriptContextProvider.recording(recordingID: f.identity.recordingID, registry: registry,
            legacy: { .legacy(text: "Wrong fallback", recordingID: f.identity.recordingID, speakerLabels: []) })
        let frozen = provider.freeze()
        #expect(try await frozen.snapshot().segments.first?.text == "Previously saved evidence")
        _ = try await writer.commitDeletionIntent()
        try await registry.discover(refresh: true)
        #expect(!loaded.isValid && registry.entry(recordingID: f.identity.recordingID) == nil)
        #expect(removed == [f.identity.recordingID] && unrelated.isValid && registry.entry(identity: unrelatedID) === unrelated)
        await #expect(throws: (any Error).self) { _ = try await frozen.snapshot() }
        await #expect(throws: (any Error).self) { _ = try await provider.freeze().snapshot() }
        await #expect(throws: LiveArtifactError.deleted) { _ = try await registry.resolve(recordingID: f.identity.recordingID) }
        #expect(registry.isKnownDeleted(recordingID: f.identity.recordingID) && !registry.hasPendingDeletion(recordingID: f.identity.recordingID))
        #expect(try await registry.resolve(recordingID: f.identity.recordingID, forDeletion: true) == nil)
        #expect(registry.hasPendingDeletion(recordingID: f.identity.recordingID))
        try await registry.deleteArtifacts(recordingID: f.identity.recordingID)
        registry.completeDeletion(recordingID: f.identity.recordingID)
    }

    @Test func delayedCatalogueResultsKeepTheirOwnReservationAcrossANewerScan() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Saved"), revision: 1)
        let gate = LiveArtifactGate(stage: .cataloguePublication)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let first = Task { try await registry.discover() }
        do {
            try await gate.waitForArrival()
            try await registry.discover()
            try await registry.discover(refresh: true)
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes + LiveManagedArtifactCatalogue.hintByteLimit)
            await gate.release(); try await first.value
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        } catch { await gate.release(); _ = try? await first.value; throw error }
    }

    @Test func delayedDiscoveryWaiterReusesTheOwnerInstalledByAnotherCaller() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Shared"), revision: 1)
        let gate = LiveArtifactGate(stage: .registryResolution)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let first = Task { try await registry.resolve(recordingID: f.identity.recordingID) }
        do {
            try await gate.waitForArrival()
            let other = try #require(try await registry.resolve(recordingID: f.identity.recordingID))
            await gate.release()
            #expect(try await first.value === other)
            #expect(registry.pendingLoads == 0)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
        } catch { await gate.release(); _ = try? await first.value; throw error }
    }

    @Test func orphanOwnedChatCannotFallBackToAnOrdinaryHistoryWriter() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Owned conversation"), revision: 3)
        try await writer.bind(to: f.audio)
        let url = f.audio.deletingPathExtension().appendingPathExtension("chat.json")
        let original = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: f.session)
        try FileManager.default.removeItem(at: f.audio.deletingPathExtension().appendingPathExtension("live-binding.json"))
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        await #expect(throws: (any Error).self) { _ = try await registry.resolve(recordingID: f.identity.recordingID, audioURL: f.audio) }
        #expect(try registry.entry(recordingID: f.identity.recordingID) == nil && Data(contentsOf: url) == original)
    }

    @Test func aDeletedCatalogueHintCannotBecomeHealthyWhenItsIntentDisappears() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Deleted conversation"), revision: 3)
        _ = try await writer.commitDeletionIntent()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        try await registry.discover()
        try FileManager.default.removeItem(at: f.session.appendingPathComponent("deletion.json"))
        await #expect(throws: (any Error).self) { _ = try await registry.resolve(recordingID: f.identity.recordingID, forDeletion: true) }
        #expect(registry.entry(recordingID: f.identity.recordingID) == nil && !registry.hasPendingDeletion(recordingID: f.identity.recordingID))
        await #expect(throws: LiveArtifactError.deleted) { _ = try await registry.resolve(recordingID: f.identity.recordingID) }
    }

    @Test func anInitialEmptyScanDoesNotMakeALaterOwnedRecordingLegacy() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        try await registry.discover()
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Later saved"), revision: 1)
        let loaded = try #require(try await registry.resolve(recordingID: f.identity.recordingID))
        #expect(try await loaded.artifacts.loadChat()?.messages.first?.content == "Later saved")
    }

    @Test func aKnownOwnerCannotHydrateEmptyEvidenceAfterItsOnlyPayloadDisappears() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Only payload"), revision: 1)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        try await registry.discover()
        try FileManager.default.removeItem(at: f.session.appendingPathComponent("chat.json"))
        await #expect(throws: (any Error).self) { _ = try await registry.resolve(recordingID: f.identity.recordingID) }
        #expect(registry.entry(recordingID: f.identity.recordingID) == nil)
    }

    @Test func nativeV1FinalProofReloadsReadOnlyAndAnchorsTheNextVerifiedRichPublication() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let store = LiveTranscriptStore(identity: f.identity), publicationID = UUID()
        #expect(await store.close(owner: f.identity) == .accepted)
        let publication = TranscriptSourcePublication(identity: f.identity, id: publicationID, revision: 7,
            segments: [.init(id: .init(epochID: publicationID, index: 0), source: .finalMix,
                range: .init(samples: nil, meeting: nil), text: "Previously committed final")])
        #expect(await store.publishFinal(publication) == .accepted)
        let checkpoint = await store.checkpoint()
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveTranscript(checkpoint)
        let original = try Data(contentsOf: f.session.appendingPathComponent("live-transcript.json"))
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let loaded = try #require(try await registry.resolve(recordingID: f.identity.recordingID))
        try await loaded.artifacts.flush(); try loaded.artifacts.bind(to: f.audio); try await loaded.artifacts.flush()
        let readOnly = try LiveTranscriptArtifactCodec.decode(Data(contentsOf: f.audio.deletingPathExtension().appendingPathExtension("live-transcript.json")))
        #expect(readOnly.app == nil && readOnly.native?.finalPublication == publication)
        #expect(try readOnly.encoded(generation: nil, limit: 3 * 1_024 * 1_024) == original)
        try loaded.artifacts.publishSavedFinal(.init(segments: [.init(start: 0, end: 1, text: "Verified user edit", originalText: "Previously committed final", speakerId: "You")]))
        try await loaded.artifacts.flush()
        let saved = try #require(try await writer.recover().appTranscript)
        #expect(saved.revision == checkpoint.revision + 1 && saved.native == checkpoint)
        #expect(saved.finalPublication?.id == publicationID && saved.finalPublication?.revision == 8)
        #expect(saved.finalPublication?.segments.first?.text == "Verified user edit")
    }

    @Test func interruptedNativeV1PrefixFlushBindAndEvictionKeepItsFingerprint() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let store = LiveTranscriptStore(identity: f.identity)
        let epoch = LiveEpoch(id: UUID(), source: .microphone, engineRevision: "fixture", language: "auto", meetingOriginNanoseconds: 0)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        let checkpoint = await store.checkpoint()
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveTranscript(checkpoint)
        let original = try Data(contentsOf: f.session.appendingPathComponent("live-transcript.json"))
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var entry = try await registry.resolve(recordingID: f.identity.recordingID)
        try #require(entry?.captureClosed == true && entry?.artifacts.isDurable == true)
        #expect(await entry?.store.checkpoint() == checkpoint)
        try await entry?.artifacts.flush()
        #expect(try Data(contentsOf: f.session.appendingPathComponent("live-transcript.json")) == original)
        try entry?.artifacts.bind(to: f.audio); try await entry?.artifacts.flush()
        let target = try LiveTranscriptArtifactCodec.decode(Data(contentsOf: f.audio.deletingPathExtension().appendingPathExtension("live-transcript.json")))
        #expect(target.app == nil)
        #expect(try target.encoded(generation: nil, limit: 3 * 1_024 * 1_024) == original)
        let oldValidity = try #require(entry).validity
        let next = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let pin = entry?.artifacts.pin()
        #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { _ = try registry.registerLegacy(next) }
        pin?.release(); entry = nil
        _ = try registry.registerLegacy(next)
        #expect(throws: (any Error).self) { try oldValidity.withValidResult {} }
        try registry.retire(next)
        entry = try await registry.resolve(recordingID: f.identity.recordingID, audioURL: f.audio)
        #expect(entry?.validity !== oldValidity && entry?.artifacts.isDurable == true)
        #expect(await entry?.store.checkpoint() == checkpoint)
        #expect(try LiveTranscriptArtifactCodec.decode(Data(contentsOf: f.audio.deletingPathExtension().appendingPathExtension("live-transcript.json")))
            .encoded(generation: nil, limit: 3 * 1_024 * 1_024) == original)
    }

    @Test func largeLegacyFinalAndInterruptedChatRestoreExactIDsAndAdvanceOnlyNewWrites() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let segment = LiveTranscriptSegment(start: 0, end: 1, text: String(repeating: "x", count: 30_000), speaker: "You")
        let final = LiveAppFinalPublication(id: UUID(), revision: 7,
            transcript: .init(segments: [.init(start: 0, end: 1, text: "Final text", originalText: "Final text", speakerId: "You")]))
        let artifact = LiveTranscriptArtifact(identity: f.identity, revision: 42, legacy: [.init(segment)], captureClosed: true, finalPublication: final)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveTranscript(artifact)
        var history = f.history("A saved question"); history.messages.append(.init(role: .assistant, content: "Partial answer", outcome: .streaming))
        try await writer.saveChat(history, revision: 19)
        let transcriptURL = f.session.appendingPathComponent("live-transcript.json"), original = try Data(contentsOf: transcriptURL)
        #expect(original.count > 16 * 1_024)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let entry = try #require(try await registry.resolve(recordingID: f.identity.recordingID))
        #expect(entry.artifacts.acceptedRevision == 42)
        #expect(try entry.artifacts.legacyContext().segments.first?.id == segment.id.uuidString.lowercased())
        #expect(try entry.artifacts.finalContext()?.source.publicationID == final.id)
        #expect(try entry.artifacts.finalContext()?.source.publicationRevision == 7)
        let loaded = try #require(try await entry.artifacts.loadChat())
        #expect(loaded.revision == 19 && loaded.messages.last?.outcome == .interrupted)
        try await entry.artifacts.flush(); #expect(try Data(contentsOf: transcriptURL) == original)
        try entry.artifacts.saveChat(loaded, urgent: true); try await entry.artifacts.flush()
        #expect(entry.artifacts.acceptedChatRevision == 20 && entry.artifacts.acceptedRevision == 42)
        try entry.artifacts.publishSavedFinal(.init(segments: [.init(start: 1, end: 2, text: "User edit", originalText: "User edit", speakerId: "You")]))
        try await entry.artifacts.flush()
        let saved = try #require(try await writer.recover().appTranscript)
        #expect(saved.revision == 43 && saved.finalPublication?.id == final.id && saved.finalPublication?.revision == 8)
    }

    @Test func chatOnlyHistoryKeepsMissingEvidenceWithoutFabricatingCapturedText() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Only saved conversation"), revision: 3)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        let entry = try #require(try await registry.resolve(recordingID: f.identity.recordingID))
        #expect(throws: LiveArtifactError.missingEvidence) { _ = try entry.artifacts.legacyContext() }
        try await entry.artifacts.flush()
        #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("live-transcript.json").path))
        try entry.artifacts.publishFinal(.init(text: "Later committed final", segments: []))
        try await entry.artifacts.flush()
        let saved = try #require(try await writer.recover().appTranscript)
        #expect(saved.sourceUnavailable == true && saved.native == nil && saved.legacy == nil)
        #expect(saved.finalPublication?.fallbackText == "Later committed final")
        try saved.validate()
    }

    @Test func concurrentLoadsShareOneOwnerAndCancelledCallerDoesNotReturnItsLease() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Shared"), revision: 4)
        let gate = LiveArtifactGate(stage: .historyLoad)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        try await registry.discover()
        let first = Task { try await registry.resolve(recordingID: f.identity.recordingID) }
        do {
            try await gate.waitForArrival()
            let second = Task { try await registry.resolve(recordingID: f.identity.recordingID) }
            try await f.eventually { await MainActor.run { registry.pendingLoadWaiters == 2 } }
            first.cancel()
            #expect(registry.pendingLoads == 1)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await gate.release()
            await #expect(throws: CancellationError.self) { _ = try await first.value }
            let loaded = try #require(try await second.value)
            #expect(registry.entry(recordingID: f.identity.recordingID) === loaded)
            #expect(registry.pendingLoads == 0 && registry.pendingLoadWaiters == 0)
            #expect(try await loaded.artifacts.loadChat()?.messages.first?.content == "Shared")
        } catch { await gate.release(); _ = try? await first.value; throw error }
    }

    @Test func retirementDuringHeldLoadCannotInstallAStaleOwner() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Old"), revision: 1)
        let gate = LiveArtifactGate(stage: .historyLoad)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        try await registry.discover()
        let load = Task { try await registry.resolve(recordingID: f.identity.recordingID) }
        do {
            try await gate.waitForArrival(); try registry.retire(f.identity)
            #expect(registry.pendingLoads == 1)
            await gate.release()
            await #expect(throws: (any Error).self) { _ = try await load.value }
            #expect(registry.entry(recordingID: f.identity.recordingID) == nil && registry.pendingLoads == 0)
        } catch { await gate.release(); _ = try? await load.value; throw error }
    }

    @Test(arguments: ["deletion", "history", "audio"])
    func changesAfterPhysicalRecoveryCannotPublishAStaleOwner(change: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Original"), revision: 1)
        if change == "audio" { try await writer.bind(to: f.audio) }
        let gate = LiveArtifactGate(stage: .ownerHydration)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let load = Task { try await registry.resolve(recordingID: f.identity.recordingID) }
        do {
            try await gate.waitForArrival()
            if change == "deletion" { _ = try await writer.commitDeletionIntent() }
            else {
                let url = change == "audio" ? f.audio : f.session.appendingPathComponent("chat.json")
                try Data("Foreign replacement".utf8).write(to: url, options: .atomic)
            }
            await gate.release()
            await #expect(throws: (any Error).self) { _ = try await load.value }
            #expect(registry.entry(recordingID: f.identity.recordingID) == nil && registry.pendingLoads == 0)
        } catch { await gate.release(); _ = try? await load.value; throw error }
    }

    @Test func loadWaiterAdmissionIsBoundedBeforeTasksAccumulate() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Shared"), revision: 1)
        let gate = LiveArtifactGate(stage: .historyLoad)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        try await registry.discover()
        let first = Task { try await registry.resolve(recordingID: f.identity.recordingID) }
        var others: [Task<Bool, Never>] = []
        do {
            try await gate.waitForArrival()
            for _ in 0..<8 {
                others.append(Task {
                    do { return try await registry.resolve(recordingID: f.identity.recordingID) != nil }
                    catch LiveRecordingSessionRegistry.Failure.capacity { return false }
                    catch { Issue.record(error); return false }
                })
            }
            try await f.eventually { await MainActor.run { registry.pendingLoadWaiters == 8 } }
            #expect(registry.pendingLoads == 1)
            await gate.release(); _ = try await first.value
            var accepted = 0
            for other in others { if await other.value { accepted += 1 } }
            #expect(accepted == 7 && registry.pendingLoads == 0)
        } catch { await gate.release(); _ = try? await first.value; for other in others { _ = await other.value }; throw error }
    }

    @Test func managedCatalogueCountAndNamespaceAdmissionStayFinite() async throws {
        let f = try LiveArtifactFixture()
        do {
            try await Task.detached {
                for _ in 0...LiveManagedArtifactCatalogue.hintLimit {
                    let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
                    let directory = f.root.appendingPathComponent(identity.captureSessionID.uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(ChatHistory(messages: [], identity: identity, revision: 1)).write(to: directory.appendingPathComponent("chat.json"))
                }
            }.value
            let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
            await #expect(throws: LiveArtifactError.artifactTooLarge) { try await registry.discover() }
            #expect(registry.discoveryFailure != nil && registry.pendingLoads == 0)
            let empty = LiveRecordingSessionRegistry(artifactRoot: f.root.appendingPathComponent("unused"))
            for _ in 0..<LiveManagedArtifactCatalogue.hintLimit { empty.noteUnavailable(.init(recordingID: UUID(), captureSessionID: UUID())) }
            #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { _ = try empty.registerLegacy(.init(recordingID: UUID(), captureSessionID: UUID())) }
            await Task.detached { f.remove() }.value
        } catch { await Task.detached { f.remove() }.value; throw error }
    }

    @Test func discoveryPreventsANewCaptureFromOverwritingAColdRecordingNamespace() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).saveChat(f.history("Cold"), revision: 1)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        try await registry.discover()
        #expect(throws: (any Error).self) { _ = try registry.registerLegacy(f.identity) }
        #expect(throws: (any Error).self) { _ = try registry.registerLegacy(.init(recordingID: f.identity.recordingID, captureSessionID: UUID())) }
        #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().chat?.messages.first?.content == "Cold")
    }

    @Test(arguments: ["unsupported", "duplicate", "oversized", "symlink", "renamedDirectory", "hiddenDirectory"])
    func unknownCatalogueNeverConfirmsLegacyOrChangesBytes(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try FileManager.default.createDirectory(at: f.session, withIntermediateDirectories: true)
        let url = f.session.appendingPathComponent("live-transcript.json")
        var json = "{\"version\":99,\"identity\":{\"recordingID\":\"\(f.identity.recordingID)\",\"captureSessionID\":\"\(f.identity.captureSessionID)\"}}"
        if kind == "duplicate" { json = json.replacingOccurrences(of: "99", with: "1,\"version\":2") }
        if kind == "oversized" { json = String(repeating: " ", count: 3 * 1_024 * 1_024 + 1) }
        if kind == "symlink" { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.audio) }
        else { try Data(json.utf8).write(to: url) }
        let original = try Data(contentsOf: url)
        let preservedURL: URL
        if kind == "renamedDirectory" || kind == "hiddenDirectory" {
            let moved = f.root.appendingPathComponent(kind == "hiddenDirectory" ? ".renamed-owned-session" : "renamed-owned-session")
            try FileManager.default.moveItem(at: f.session, to: moved)
            preservedURL = moved.appendingPathComponent("live-transcript.json")
        } else { preservedURL = url }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        await #expect(throws: (any Error).self) { _ = try await registry.resolve(recordingID: UUID(), audioURL: f.audio) }
        #expect(registry.discoveryFailure != nil && registry.entry(recordingID: f.identity.recordingID) == nil)
        #expect(try Data(contentsOf: preservedURL) == original)
    }

    @Test func inspectionAdmissionFailsBeforeReadingAnyHeadersAtAggregateCapacity() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let budget = LiveRecordingPayloadBudget(ownerLimit: 8)
        let held = try budget.reserveAuxiliary(bytes: 127 * 1_024 * 1_024)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, payloadBudget: budget)
        await #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { try await registry.discover() }
        #expect(registry.reservedPayloadBytes == 128 * 1_024 * 1_024)
        withExtendedLifetime(held) {}
    }

    @Test func aSavedDeletionIntentIsCleanupAuthorityAndCannotBecomeAProvider() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Delete me"), revision: 1); try await writer.bind(to: f.audio)
        _ = try await writer.commitDeletionIntent()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        await #expect(throws: LiveArtifactError.deleted) { _ = try await registry.resolve(recordingID: f.identity.recordingID) }
        #expect(try await registry.resolve(recordingID: f.identity.recordingID, audioURL: f.audio, forDeletion: true) == nil)
        #expect(registry.hasPendingDeletion(recordingID: f.identity.recordingID))
        #expect(FileManager.default.fileExists(atPath: f.audio.deletingPathExtension().appendingPathExtension("chat.json").path))
        try await registry.deleteArtifacts(recordingID: f.identity.recordingID)
        #expect(!FileManager.default.fileExists(atPath: f.audio.deletingPathExtension().appendingPathExtension("chat.json").path))
        registry.completeDeletion(recordingID: f.identity.recordingID)
        #expect(registry.entry(recordingID: f.identity.recordingID) == nil)
    }
}
