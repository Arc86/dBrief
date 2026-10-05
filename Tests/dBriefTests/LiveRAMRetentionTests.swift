import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveRAMRetentionTests {
    private let maintenance = 224 * 1_024
    private func begin(_ f: RAMRetentionFixture, _ registry: LiveRecordingSessionRegistry) throws -> LiveRecordingSessionRegistry.RAMTranscriptRetention {
        try #require(try registry.beginRAMTranscriptRetention(recordingID: f.identity.recordingID, olderThan: f.cutoff, folders: [f.intended, f.saved]))
    }
    @Test func activeCaptureFreshFinalAndOriginalPinDeferWithoutExtraCharge() throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live)
        let entry = try f.register(registry, closed: false), charge = registry.reservedPayloadBytes
        #expect(try registry.beginRAMTranscriptRetention(recordingID: f.identity.recordingID, olderThan: f.cutoff, folders: [f.intended]) == nil)
        try registry.captureDidClose(f.identity)
        var value: TranscriptContextSnapshot? = try entry.artifacts.legacyContext()
        #expect(!entry.artifacts.canExpire)
        #expect(try registry.beginRAMTranscriptRetention(recordingID: f.identity.recordingID, olderThan: f.cutoff, folders: [f.intended]) == nil)
        value = nil
        #expect(entry.artifacts.canExpire)
        try entry.artifacts.publishFinal(.init(text: "Fresh final"))
        #expect(try registry.beginRAMTranscriptRetention(recordingID: f.identity.recordingID, olderThan: f.cutoff, folders: [f.intended]) == nil)
        #expect(throws: LiveArtifactError.corruptArtifact) { _ = try registry.beginRAMTranscriptRetention(recordingID: f.identity.recordingID, olderThan: .init(timeIntervalSinceReferenceDate: .nan), folders: [f.intended]) }
        #expect(registry.reservedPayloadBytes == charge && entry.isValid && registry.entry(recordingID: f.identity.recordingID) === entry)
        withExtendedLifetime(value) {}
    }
    @Test(arguments: ["audio", "metadata", "unsupported", "foreign", "offline"])
    func associatedFolderBCannotDowngradeToAccessibleIntendedA(kind: String) async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live)
        let entry = try f.register(registry, bound: true)
        let raw = try f.write("transcript.json", data: Data("Old conventional".utf8))
        if kind == "audio" { try FileManager.default.removeItem(at: f.audio) }
        if kind == "metadata" { try FileManager.default.removeItem(at: f.metadata) }
        if kind == "unsupported" { try Data("{}".utf8).write(to: f.metadata, options: .atomic) }
        if kind == "foreign" { try f.writeMetadata(id: UUID()) }
        if kind == "offline" { try FileManager.default.moveItem(at: f.saved, to: f.root.appendingPathComponent("offline")) }
        let phase = try begin(f, registry)
        try await registry.runRAMTranscriptRetention(phase)
        #expect(!phase.intentCommitted && entry.isValid && registry.entry(recordingID: f.identity.recordingID) === entry)
        #expect(registry.retentionHints.first?.ram?.sourceRetired == false && registry.pendingRAMTranscriptRetentions == 0)
        if kind != "offline" { #expect(try Data(contentsOf: raw) == Data("Old conventional".utf8)) }
        #expect(entry.artifacts.admittedAudioURL != nil)
    }
    @Test func actualAssociatedClosedInventoryRemovesOnlyAgedOutputsAndArchivesRAMPolicy() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let calls = RAMRetentionCalls()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { calls.record($0) })
        let entry = try f.register(registry, bound: true), validity = entry.validity
        let note = f.saved.appendingPathComponent("linked.md")
        try f.oldWrite(Data("Linked exported note".utf8), note)
        let insights = RecordingInsights(summary: "Summary", actionItems: [], tags: [], sentiment: "neutral", markdownPath: note.path)
        let selected = [try f.write("transcript.json", data: Data("Raw".utf8)), try f.write("insights.json", data: JSONEncoder().encode(insights)),
                        try f.write("chat.json", data: JSONEncoder().encode(ChatHistory(messages: [.init(role: .user, content: "Ordinary saved chat")]))), note]
        let newer = try f.write("richtranscript.json", data: Data("Newer retained".utf8), old: false)
        let foreign = f.saved.appendingPathComponent("foreign.md"), privateFile = try f.write("privacy.json", data: Data("Private evidence".utf8))
        try f.oldWrite(Data("Foreign note".utf8), foreign)
        let preserved = [f.audio, f.metadata, newer, foreign, privateFile], bytes = try preserved.map { try Data(contentsOf: $0) }
        let expected = try selected.reduce(Int64(0)) { $0 + Int64(try Data(contentsOf: $1).count) }
        let phase = try begin(f, registry)
        try await registry.runRAMTranscriptRetention(phase)
        let progress = await registry.ramTranscriptRetentionProgress(phase)
        #expect(phase.intentCommitted && progress.cleanupComplete && progress.removedFiles == selected.count && progress.bytesRemoved == expected && progress.pendingSyncs == 0)
        #expect(selected.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try preserved.map { try Data(contentsOf: $0) } == bytes)
        #expect(!entry.isValid && registry.owns(recordingID: f.identity.recordingID) && !registry.isKnownDeleted(recordingID: f.identity.recordingID))
        #expect(throws: CancellationError.self) { try validity.withValidResult {} }
        let hint = try #require(registry.retentionHints.first)
        #expect(!hint.capturePersistenceAllowed && hint.ram?.sourceRetired == true && hint.ram?.capture == f.capture && hint.audioURL == entry.artifacts.admittedAudioURL)
        calls.clear()
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await registry.resolve(recordingID: f.identity.recordingID, audioURL: f.audio) }
        await #expect(throws: LiveArtifactError.missingEvidence) { _ = try await registry.prepareHistoryExport(recordingID: f.identity.recordingID, audioURL: f.audio) }
        var fallback = 0
        let provider = TranscriptContextProvider.recording(recordingID: f.identity.recordingID, registry: registry) {
            fallback += 1; return .legacy(text: "", recordingID: f.identity.recordingID, speakerLabels: [])
        }
        await #expect(throws: LiveArtifactError.wrongOwner) { _ = try await provider.freeze().snapshot() }
        #expect(fallback == 0 && calls.values.isEmpty && registry.pendingLoads == 0)
        #expect(!FileManager.default.fileExists(atPath: f.live.path))
    }
    @Test func genuinelyUnassociatedSourceHasPermanentEmptyTicket() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .retentionIntent)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { try await gate.enter($0) })
        let entry = try f.register(registry)
        let plausible = try f.write("transcript.json", data: Data("Must remain".utf8))
        let phase = try begin(f, registry), operation = Task { try await registry.runRAMTranscriptRetention(phase) }
        do {
            try await gate.waitForArrival()
            let late = f.intended.appendingPathComponent("late.txt"); try f.oldWrite(Data("Late".utf8), late)
            await gate.release(); try await operation.value
            let progress = await registry.ramTranscriptRetentionProgress(phase)
            #expect(progress.inventoryCount == 0 && progress.removedFiles == 0 && phase.intentCommitted && !entry.isValid)
            #expect(try Data(contentsOf: plausible) == Data("Must remain".utf8) && Data(contentsOf: late) == Data("Late".utf8))
        } catch { await gate.release(); _ = try? await operation.value; throw error }
    }
    @Test func heldWorksheetSharesOneActualTaskAndAbandonWaitsForItsReturn() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .ramRetentionPrepared), calls = RAMRetentionCalls()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { calls.record($0); try await gate.enter($0) })
        let entry = try f.register(registry, bound: true), base = registry.reservedPayloadBytes
        _ = try f.write("transcript.json", data: Data("Preserved".utf8))
        let phase = try begin(f, registry)
        var tasks = [Task { try await registry.runRAMTranscriptRetention(phase) }]
        do {
            try await gate.waitForArrival()
            for _ in 1..<8 { tasks.append(Task { try await registry.runRAMTranscriptRetention(phase) }) }
            try await f.fixture.eventually { await MainActor.run { registry.pendingRAMRetentionWaiters == 8 } }
            await #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { try await registry.runRAMTranscriptRetention(phase) }
            tasks[0].cancel(); registry.abandonRAMTranscriptRetention(phase)
            #expect(registry.entry(recordingID: f.identity.recordingID) == nil && entry.isValid && !phase.intentCommitted)
            #expect(registry.reservedPayloadBytes == base + maintenance)
            #expect(throws: LiveArtifactError.deleted) { _ = try entry.artifacts.legacyContext() }
            #expect(throws: LiveRecordingSessionRegistry.Failure.unavailable) { _ = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false) }
            #expect(calls.values.filter { $0 == .ramRetentionPrepared }.count == 1)
            await gate.release()
            await #expect(throws: CancellationError.self) { try await tasks[0].value }
            for task in tasks.dropFirst() { try await task.value }
            #expect(registry.entry(recordingID: f.identity.recordingID) === entry && entry.isValid && registry.pendingRAMTranscriptRetentions == 0)
            #expect(registry.reservedPayloadBytes == base + maintenance)
            #expect(try entry.artifacts.legacyContext().segments.first?.text == "Captured prefix")
        } catch { await gate.release(); for task in tasks { _ = try? await task.value }; throw error }
    }
    @Test(arguments: ["final", "audio", "output"])
    func changedFactsOrPhysicalAuthorityDuringPreparationCannotBeRemoved(kind: String) async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .ramRetentionPrepared)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { try await gate.enter($0) })
        let entry = try f.register(registry, bound: true), selected = try f.write("transcript.json", data: Data("Exact".utf8))
        let phase = try begin(f, registry), operation = Task { try await registry.runRAMTranscriptRetention(phase) }
        do {
            try await gate.waitForArrival()
            if kind == "final" { try entry.artifacts.publishFinal(.init(text: "Fresh")) }
            else { let url = kind == "audio" ? f.audio : selected; try Data(contentsOf: url).write(to: url, options: .atomic) }
            await gate.release()
            if kind == "final" { try await operation.value }
            else { await #expect(throws: LiveArtifactError.wrongOwner) { try await operation.value } }
            #expect(entry.isValid && registry.entry(recordingID: f.identity.recordingID) === entry && !phase.intentCommitted)
            #expect(try Data(contentsOf: selected) == Data("Exact".utf8))
        } catch { await gate.release(); _ = try? await operation.value; throw error }
    }
    @Test(arguments: [false, true])
    func actualUnlinkIsRecordedBeforeSyncErrorAndRetryCannotDeleteRecreatedName(recreate: Bool) async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let fault = RAMSyncFault(), registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeRAMDirectorySync: { try fault.check($0) })
        _ = try f.register(registry, bound: true)
        let selected = try f.write("transcript.json", data: Data("Physical original".utf8))
        let phase = try begin(f, registry)
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await registry.runRAMTranscriptRetention(phase) }
        let failed = await registry.ramTranscriptRetentionProgress(phase)
        #expect(phase.intentCommitted && failed.completedSteps == 1 && failed.pendingSyncs == 1 && failed.removedFiles == 1 && !failed.cleanupComplete)
        #expect(!FileManager.default.fileExists(atPath: selected.path) && registry.pendingRAMTranscriptRetentions == 1)
        if recreate {
            try f.oldWrite(Data("Physical original".utf8), selected)
            await #expect(throws: LiveArtifactError.wrongOwner) { try await registry.runRAMTranscriptRetention(phase) }
            #expect(try Data(contentsOf: selected) == Data("Physical original".utf8) && fault.calls == 1)
        } else {
            try await registry.runRAMTranscriptRetention(phase)
            let done = await registry.ramTranscriptRetentionProgress(phase)
            #expect(done.cleanupComplete && done.removedFiles == 1 && done.pendingSyncs == 0 && fault.calls == 2)
        }
    }
    @Test(arguments: [false, true])
    func absentOrAlreadyRemovedMarkdownCannotBeAdoptedBeforeProof(absent: Bool) async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: absent ? .retentionRemoval : .ramRetentionRemoved)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { try await gate.enter($0) })
        _ = try f.register(registry, bound: true)
        let note = f.saved.appendingPathComponent("linked.md")
        if !absent { try f.oldWrite(Data("Original Markdown".utf8), note) }
        let proof = try f.write("insights.json", data: JSONEncoder().encode(RecordingInsights(summary: "Summary", actionItems: [], tags: [], sentiment: "neutral", markdownPath: note.path)))
        let bytes = try Data(contentsOf: proof), phase = try begin(f, registry), operation = Task { try await registry.runRAMTranscriptRetention(phase) }
        do {
            try await gate.waitForArrival()
            #expect(phase.intentCommitted && !FileManager.default.fileExists(atPath: note.path))
            try f.oldWrite(Data("New unrelated Markdown".utf8), note)
            await gate.release()
            await #expect(throws: LiveArtifactError.wrongOwner) { try await operation.value }
            #expect(try Data(contentsOf: proof) == bytes && Data(contentsOf: note) == Data("New unrelated Markdown".utf8))
            let progress = await registry.ramTranscriptRetentionProgress(phase)
            #expect(progress.removedFiles == (absent ? 0 : 1) && !progress.cleanupComplete)
        } catch { await gate.release(); _ = try? await operation.value; throw error }
    }
    @Test func heldCompletionAndCanceledWaiterRetainOriginalOwnerUntilActualJoin() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .retentionCompleted)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { try await gate.enter($0) })
        var original: LiveRecordingSessionRegistry.Entry? = try f.register(registry, bound: true)
        let probe = RAMRetentionWeak(original)
        let phase = try begin(f, registry), baseline = registry.reservedPayloadBytes
        var operation: Task<Void, Error>? = Task { try await registry.runRAMTranscriptRetention(phase) }
        do {
            original = nil; try await gate.waitForArrival(); operation?.cancel()
            #expect(probe.entry != nil && phase.intentCommitted && registry.reservedPayloadBytes == baseline)
            #expect(registry.pendingRAMTranscriptRetentions == 1)
            _ = registry.freezeForTermination()
            await gate.release()
            await #expect(throws: CancellationError.self) { try await operation?.value }
            operation = nil
            try await f.fixture.eventually { await MainActor.run { probe.entry == nil && registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes + 224 * 1_024 } }
        } catch { await gate.release(); _ = try? await operation?.value; throw error }
    }
    @Test(arguments: ["queue.json", "live-binding.json", "live-transcript.json", "reprocessing.json", "foreignChat", "unknownChat", "newerChat", "wrongFolder"])
    func explicitNegativeOwnershipAndScopePreserveExistingFiles(kind: String) async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live)
        let original = try f.register(registry, bound: true)
        let preserved: URL
        if kind.hasSuffix("Chat") {
            var history = ChatHistory(messages: [.init(role: .user, content: "Preserved saved history")])
            if kind == "foreignChat" { history.identity = .init(recordingID: UUID(), captureSessionID: UUID()) }
            if kind == "unknownChat" { history.version = 99 }
            preserved = try f.write("chat.json", data: JSONEncoder().encode(history), old: kind != "newerChat")
        } else { preserved = try f.write(kind == "wrongFolder" ? "transcript.json" : kind, data: Data("Opaque retained file".utf8)) }
        let bytes = try Data(contentsOf: preserved)
        let folders = kind == "wrongFolder" ? [f.intended] : [f.intended, f.saved]
        let phase = try #require(try registry.beginRAMTranscriptRetention(recordingID: f.identity.recordingID, olderThan: f.cutoff, folders: folders))
        try await registry.runRAMTranscriptRetention(phase)
        #expect(try Data(contentsOf: preserved) == bytes)
        #expect(phase.intentCommitted == (kind == "newerChat"))
        if kind != "newerChat" { #expect(original.isValid && registry.entry(recordingID: f.identity.recordingID) === original) }
    }
    @Test func noWindowQuitSealsHeldPreparationAndCannotCommitANewIntent() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .ramRetentionPrepared)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { try await gate.enter($0) })
        let original = try f.register(registry, bound: true)
        let selected = try f.write("transcript.json", data: Data("Kept at Quit".utf8))
        let phase = try begin(f, registry), charge = registry.reservedPayloadBytes
        let operation = Task { try await registry.runRAMTranscriptRetention(phase) }
        do {
            try await gate.waitForArrival(); operation.cancel()
            let census = registry.freezeForTermination()
            #expect(census.owners.isEmpty && census.loads.isEmpty && original.isValid && registry.reservedPayloadBytes == charge)
            #expect(throws: LiveArtifactError.terminating) { _ = try original.artifacts.legacyContext() }
            await gate.release()
            await #expect(throws: CancellationError.self) { try await operation.value }
            #expect(!phase.intentCommitted && original.isValid && registry.pendingRAMTranscriptRetentions == 0)
            #expect(try Data(contentsOf: selected) == Data("Kept at Quit".utf8))
            #expect(throws: LiveArtifactError.terminating) { _ = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false) }
        } catch { await gate.release(); _ = try? await operation.value; throw error }
    }
    @Test func folderGrowthAfterWorksheetHasItsOwnBoundAndPreservesTheOriginal() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .ramRetentionQueueScan)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { try await gate.enter($0) })
        let original = try f.register(registry, bound: true)
        let selected = try f.write("transcript.json", data: Data("Exact original output".utf8))
        let base = registry.reservedPayloadBytes, phase = try begin(f, registry)
        let operation = Task { try await registry.runRAMTranscriptRetention(phase) }
        do {
            try await gate.waitForArrival()
            #expect(original.isValid && !phase.intentCommitted && registry.entry(recordingID: f.identity.recordingID) == nil)
            #expect(registry.reservedPayloadBytes == base + maintenance)
            for index in 0..<129 {
                try Data("Queue evidence".utf8).write(to: f.saved.appendingPathComponent("late-\(index).queue.json"))
            }
            await gate.release()
            await #expect(throws: LiveArtifactError.artifactTooLarge) { try await operation.value }
            #expect(original.isValid && !phase.intentCommitted && registry.entry(recordingID: f.identity.recordingID) === original)
            #expect(registry.pendingRAMTranscriptRetentions == 0 && registry.retentionHints.first?.ram?.sourceRetired == false)
            #expect(try Data(contentsOf: selected) == Data("Exact original output".utf8))
            #expect(registry.reservedPayloadBytes == base + maintenance)
        } catch { await gate.release(); _ = try? await operation.value; throw error }
    }
    @Test func sevenDurablePhasesAndOneRAMPhaseShareTheEightPhaseLimit() throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live)
        _ = try f.register(registry)
        var durable: [LiveRecordingSessionRegistry.Replacement] = []
        for index in 0..<7 {
            let id = UUID(), audio = f.saved.appendingPathComponent("other-\(index).wav")
            try Data("Other master".utf8).write(to: audio)
            durable.append(try registry.beginReplacement(recordingID: id, audioURL: audio))
        }
        let ram = try begin(f, registry), charge = registry.reservedPayloadBytes
        #expect(registry.pendingReplacements.count == 7 && registry.pendingRAMTranscriptRetentions == 1)
        let next = f.saved.appendingPathComponent("ninth.wav"); try Data("Ninth".utf8).write(to: next)
        #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { _ = try registry.beginReplacement(recordingID: UUID(), audioURL: next) }
        #expect(registry.reservedPayloadBytes == charge)
        registry.abandonRAMTranscriptRetention(ram)
        for phase in durable { registry.abandonReplacement(phase) }
    }
    @Test func archiveCapacityFailureRestoresTheExactHealthyOriginal() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        var folder = f.intended
        for index in 0..<4 { folder.appendPathComponent(String(repeating: "x", count: 195) + String(index), isDirectory: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let capture = try LiveRAMCaptureMetadata(startedAt: f.old, intendedFolder: folder)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live)
        var overflow = false
        for _ in 0..<100 {
            let id = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
            var original: LiveRecordingSessionRegistry.Entry? = try registry.registerLegacy(id, capturePersistenceAllowed: false, ramCapture: capture)
            try registry.captureDidClose(id)
            let count = registry.retentionHints.filter { $0.ram?.sourceRetired == true }.count
            var phase: LiveRecordingSessionRegistry.RAMTranscriptRetention? = try #require(try registry.beginRAMTranscriptRetention(recordingID: id.recordingID, olderThan: f.cutoff, folders: [folder]))
            do { try await registry.runRAMTranscriptRetention(try #require(phase)) }
            catch LiveRecordingSessionRegistry.Failure.capacity {
                overflow = true
                #expect(original?.isValid == true && registry.entry(recordingID: id.recordingID) === original)
                #expect(phase?.intentCommitted == false && registry.pendingRAMTranscriptRetentions == 0)
                #expect(registry.retentionHints.filter { $0.ram?.sourceRetired == true }.count == count)
                break
            }
            #expect(phase?.intentCommitted == true)
            phase = nil; original = nil
            try await f.fixture.eventually { await MainActor.run { registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes } }
        }
        #expect(overflow)
    }
    @Test func diskCatalogueCannotOverwriteAnArchivedRAMNamespaceOrInstallPartOfProposal() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live)
        _ = try f.register(registry)
        let phase = try begin(f, registry); try await registry.runRAMTranscriptRetention(phase)
        let archived = registry.retentionHints
        let other = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        for identity in [f.identity, other] {
            let writer = LiveSessionArtifactStore(identity: identity, rootURL: f.live)
            try await writer.saveTranscript(LiveTranscriptArtifact(identity: identity, revision: 1,
                legacy: [.init(.init(start: 0, end: 1, text: "Disk source"))], captureClosed: true))
        }
        await #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { try await registry.discover(refresh: true) }
        #expect(registry.retentionHints == archived && !registry.owns(recordingID: other.recordingID) && registry.pendingLoads == 0)
    }
    @Test(arguments: [false, true])
    func archivedReplacementKeepsHintAndActualReaderLeasesThroughHeldCallback(quit: Bool) async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .ownerHydration), probe = RAMArchivedProbe()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.live)
        _ = try f.register(registry, bound: true)
        let retention = try begin(f, registry); try await registry.runRAMTranscriptRetention(retention)
        let archived = try #require(registry.retentionHints.first), baseline = registry.reservedPayloadBytes
        let replacement = try registry.beginReplacement(recordingID: f.identity.recordingID, audioURL: f.audio)
        #expect(try await registry.resolveForReplacement(replacement) == nil)
        try registry.adoptReplacement(replacement, attemptID: UUID())
        let canonical = f.audio.deletingPathExtension().appendingPathExtension("transcript.json")
        try JSONEncoder().encode(TranscriptionResult(text: "Actual held replacement")).write(to: canonical)
        let resultStore = ReprocessingStore(root: f.root.appendingPathComponent("Reprocessing"))
        registry.onHydration = { [weak registry] entry in
            guard let registry else { throw CancellationError() }
            let inspection = try registry.reserveReprocessingInspection()
            defer { withExtendedLifetime(inspection) {} }
            let current = try #require(try await resultStore.managedFinal(audioURL: f.audio, identity: f.identity, nonpersistingReplacement: true))
            try await entry.artifacts.reconcileFinal(current)
            let value = try #require(try entry.artifacts.finalContext())
            defer { withExtendedLifetime(value) {} }
            probe.entry = entry; probe.value = value
            try await gate.enter(.ownerHydration)
            try value.contextOwnership?.requireValid(); probe.returned = true
        }
        var operation: Task<LiveRecordingSessionRegistry.Entry?, Error>? = Task { try await registry.finishReplacement(replacement) }
        do {
            try await gate.waitForArrival(); operation?.cancel()
            #expect(registry.retentionHints.first == archived && registry.entry(recordingID: f.identity.recordingID) == nil)
            #expect(probe.entry?.isValid == true && !probe.returned && registry.reservedPayloadBytes == baseline + 64 * 1_024 * 1_024)
            if quit { #expect(registry.freezeForTermination().owners.isEmpty) }
            #expect(registry.retentionHints.first == archived && registry.reservedPayloadBytes == baseline + 64 * 1_024 * 1_024)
            await gate.release()
            if quit { await #expect(throws: LiveArtifactError.terminating) { _ = try await operation?.value } }
            else { await #expect(throws: CancellationError.self) { _ = try await operation?.value } }
            operation = nil
            #expect(probe.returned && probe.value?.segments.first?.text == "Actual held replacement")
            if quit {
                #expect(registry.retentionHints.first == archived && registry.entry(recordingID: f.identity.recordingID) == nil)
                #expect(throws: CancellationError.self) { try probe.value?.contextOwnership?.requireValid() }
            } else {
                let fresh = try #require(registry.entry(recordingID: f.identity.recordingID))
                #expect(fresh === probe.entry && !fresh.artifacts.capturePersistenceAllowed && fresh.artifacts.ramMetadata?.capture == f.capture)
                #expect(registry.retentionHints.first?.ram?.sourceRetired == false)
                try probe.value?.contextOwnership?.requireValid()
            }
            #expect(registry.reservedPayloadBytes == baseline + 32 * 1_024 * 1_024)
            probe.value = nil
            try await f.fixture.eventually { await MainActor.run { registry.reservedPayloadBytes == baseline + (quit ? 0 : 32 * 1_024 * 1_024) } }
            #expect(!FileManager.default.fileExists(atPath: f.live.path))
        } catch { await gate.release(); _ = try? await operation?.value; throw error }
    }
    @Test func archivedExplicitReplacementPreservesPolicyAndNeverRecoversOriginal() async throws {
        let f = try RAMRetentionFixture(); defer { f.remove() }
        let calls = RAMRetentionCalls(), registry = LiveRecordingSessionRegistry(artifactRoot: f.live, beforeStage: { calls.record($0) })
        _ = try f.register(registry, bound: true)
        let retention = try begin(f, registry); try await registry.runRAMTranscriptRetention(retention)
        let archived = try #require(registry.retentionHints.first)
        let phase = try registry.beginReplacement(recordingID: f.identity.recordingID, audioURL: f.audio)
        calls.clear()
        #expect(try await registry.resolveForReplacement(phase) == nil && calls.values.isEmpty)
        try registry.adoptReplacement(phase, attemptID: UUID())
        registry.onHydration = { entry in
            #expect(!entry.artifacts.capturePersistenceAllowed && entry.artifacts.ramMetadata?.capture == f.capture)
            throw LiveArtifactFixtureFailure.injected
        }
        await #expect(throws: LiveArtifactFixtureFailure.injected) { _ = try await registry.finishReplacement(phase) }
        #expect(registry.retentionHints.first == archived && registry.entry(recordingID: f.identity.recordingID) == nil)
        let canonical = f.audio.deletingPathExtension().appendingPathExtension("transcript.json")
        try JSONEncoder().encode(TranscriptionResult(text: "Fresh replacement")).write(to: canonical)
        let resultStore = ReprocessingStore(root: f.root.appendingPathComponent("Reprocessing"))
        registry.onHydration = { [weak registry] entry in
            guard let registry else { throw CancellationError() }
            let inspection = try registry.reserveReprocessingInspection()
            defer { withExtendedLifetime(inspection) {} }
            let current = try #require(try await resultStore.managedFinal(audioURL: f.audio, identity: f.identity, nonpersistingReplacement: true))
            try await entry.artifacts.reconcileFinal(current)
        }
        let fresh = try #require(try await registry.finishReplacement(phase))
        #expect(!fresh.artifacts.capturePersistenceAllowed && fresh.artifacts.isNonpersistingFinalOnly && fresh.artifacts.ramMetadata?.capture == f.capture)
        #expect(fresh.artifacts.ramMetadata?.sourceRetired == false && fresh.artifacts.ramMetadata?.isOlder(than: f.cutoff) == false && calls.values.isEmpty)
        #expect(registry.retentionHints.first?.ram?.sourceRetired == false)
    }
}

@MainActor private struct RAMRetentionFixture {
    let fixture: LiveArtifactFixture
    var root: URL { fixture.root }
    var identity: LiveSessionIdentity { fixture.identity }
    let intended: URL, saved: URL, live: URL, audio: URL, metadata: URL
    let old = Date.now.addingTimeInterval(-30 * 86_400), cutoff = Date.now.addingTimeInterval(-7 * 86_400)
    let capture: LiveRAMCaptureMetadata
    init() throws {
        fixture = try LiveArtifactFixture()
        intended = fixture.root.appendingPathComponent("intended", isDirectory: true)
        saved = fixture.root.appendingPathComponent("saved", isDirectory: true)
        live = fixture.root.appendingPathComponent("LiveSessions", isDirectory: true)
        audio = saved.appendingPathComponent("recording.wav"); metadata = saved.appendingPathComponent("recording.json")
        capture = try .init(startedAt: old, intendedFolder: intended)
        try FileManager.default.createDirectory(at: intended, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try Data("Model-free media".utf8).write(to: audio); try writeMetadata(id: identity.recordingID)
    }
    func writeMetadata(id: UUID) throws {
        let value = RecordingMetadataPayload(recordingID: id, dateISO8601: ISO8601DateFormatter().string(from: old), durationSeconds: 1,
            meetingTitle: "Fixture", masterFileName: audio.lastPathComponent, segmentFileNames: [], warnings: [])
        try JSONEncoder().encode(value).write(to: metadata, options: .atomic)
    }
    func register(_ registry: LiveRecordingSessionRegistry, closed: Bool = true, bound: Bool = false) throws -> LiveRecordingSessionRegistry.Entry {
        let entry = try registry.registerLegacy(identity, capturePersistenceAllowed: false, ramCapture: capture)
        try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Captured prefix")])
        if closed { try registry.captureDidClose(identity) }
        if bound { try entry.artifacts.bind(to: audio) }
        return entry
    }
    func oldWrite(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: url.path)
    }
    func write(_ suffix: String, data: Data, old: Bool = true) throws -> URL {
        let url = audio.deletingPathExtension().appendingPathExtension(suffix)
        if old { try oldWrite(data, url) } else { try data.write(to: url, options: .atomic) }
        return url
    }
    func remove() { fixture.remove() }
}
private final class RAMRetentionCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [LiveArtifactStage] = []
    func record(_ stage: LiveArtifactStage) { lock.withLock { stages.append(stage) } }
    var values: [LiveArtifactStage] { lock.withLock { stages } }
    func clear() { lock.withLock { stages.removeAll() } }
}
private final class RAMSyncFault: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func check(_ url: URL) throws {
        try lock.withLock { count += 1; if count == 1 { throw LiveArtifactFixtureFailure.injected } }
    }
}

@MainActor private final class RAMRetentionWeak {
    weak var entry: LiveRecordingSessionRegistry.Entry?
    init(_ entry: LiveRecordingSessionRegistry.Entry?) { self.entry = entry }
}

@MainActor private final class RAMArchivedProbe {
    weak var entry: LiveRecordingSessionRegistry.Entry?
    var value: TranscriptContextSnapshot?
    var returned = false
}
