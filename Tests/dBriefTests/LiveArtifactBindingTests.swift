import Foundation
import Testing
import dBriefWire
@testable import dBrief

extension LiveArtifactDurabilityTests {
@Suite("Live history binding recovery")
struct LiveArtifactBindingTests {
    @Test(arguments: ["missing", "corrupt", "unsupported", "foreign", "phase", "generation", "audio", "vector"])
    func aChangedCommittedTargetLedgerCannotAuthorizeCleanupOrRecovery(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceCleanup)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        try await writer.saveChat(f.history("Source must survive"), revision: 1)
        let binding = Task { try await writer.bind(to: f.audio) }
        do {
            try await gate.waitForArrival()
            let source = f.session.appendingPathComponent("chat.json"), managed = f.session.appendingPathComponent("binding.json")
            let target = f.audio.deletingPathExtension().appendingPathExtension("chat.json")
            let ledger = f.audio.deletingPathExtension().appendingPathExtension("live-binding.json")
            let sourceBytes = try Data(contentsOf: source), targetBytes = try Data(contentsOf: target), managedBytes = try Data(contentsOf: managed)
            var changed: Data?
            if kind == "missing" { try FileManager.default.removeItem(at: ledger) }
            else if kind == "corrupt" { changed = Data("{broken".utf8) }
            else {
                var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as? [String: Any])
                switch kind {
                case "unsupported": object["version"] = 99
                case "foreign": object["identity"] = ["recordingID": UUID().uuidString, "captureSessionID": UUID().uuidString]
                case "phase": object["phase"] = "prepared"
                case "generation": object["generation"] = UUID().uuidString
                case "audio": object["audioURL"] = f.root.appendingPathComponent("other.wav").absoluteString
                default:
                    var vector = try #require(object["chat"] as? [String: Any])
                    vector["sha256"] = String(repeating: "0", count: 64); object["chat"] = vector
                }
                changed = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            }
            if let changed { try changed.write(to: ledger, options: .atomic) }
            await gate.release()
            await #expect(throws: (any Error).self) { try await binding.value }
            await #expect(throws: (any Error).self) { _ = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover() }
            await #expect(throws: (any Error).self) { try await writer.saveChat(f.history("Late write"), revision: 2) }
            #expect(try Data(contentsOf: source) == sourceBytes)
            #expect(try Data(contentsOf: target) == targetBytes)
            #expect(try Data(contentsOf: managed) == managedBytes)
            if let changed { #expect(try Data(contentsOf: ledger) == changed) }
            else { #expect(!FileManager.default.fileExists(atPath: ledger.path)) }
        } catch {
            binding.cancel(); await gate.release(); _ = try? await binding.value
            throw error
        }
    }

    @Test(arguments: ["polyglot-chat", "managed-audio", "unsupported-media", "system-alias-managed-audio", "case-alias-managed-audio"])
    func bindingRejectsManagedOrUnsupportedMasterPathsBeforeEffects(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let stages = LiveArtifactBindingStageProbe()
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { await stages.record($0) })
        try await writer.saveChat(f.history("Preserve"), revision: 1)
        let source = f.session.appendingPathComponent("chat.json")
        let aliased = kind == "system-alias-managed-audio" || kind == "case-alias-managed-audio"
        let audio: URL
        if kind == "system-alias-managed-audio" {
            // Foundation's system temporary path can name the same directory
            // through either /var or /private/var.
            let path = f.session.path.hasPrefix("/private/var/") ? String(f.session.path.dropFirst(8)) : "/private" + f.session.path
            audio = URL(fileURLWithPath: path).appendingPathComponent("chat.wav")
        } else if kind == "case-alias-managed-audio" {
            audio = f.root.appendingPathComponent(f.identity.captureSessionID.uuidString.lowercased()).appendingPathComponent("chat.wav")
        } else {
            audio = kind == "polyglot-chat" ? source : kind == "managed-audio" ? f.session.appendingPathComponent("recording.wav") : f.root.appendingPathComponent("recording.txt")
        }
        let metadata = RecordingMetadataPayload(recordingID: f.identity.recordingID, dateISO8601: "fixture", durationSeconds: 1,
            meetingTitle: "fixture", masterFileName: audio.lastPathComponent, segmentFileNames: [], warnings: [])
        let aliasExists = FileManager.default.fileExists(atPath: audio.deletingLastPathComponent().path)
        if kind == "polyglot-chat" || aliased && aliasExists {
            if aliased { try Data("Model-free master through directory alias".utf8).write(to: audio) }
            var combined = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
            let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
            combined.merge(fields, uniquingKeysWith: { _, value in value })
            try JSONSerialization.data(withJSONObject: combined, options: .sortedKeys).write(to: source)
        } else if !aliased {
            try Data("Model-free master".utf8).write(to: audio)
            try JSONEncoder().encode(metadata).write(to: audio.deletingPathExtension().appendingPathExtension("json"))
        }
        let before = try files(in: f.root)
        await #expect(throws: (any Error).self) { try await writer.bind(to: audio) }
        #expect(await stages.preparedCount == 0)
        #expect(try files(in: f.root) == before)
    }

    private func files(in root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }

    @Test(arguments: [LiveArtifactStage.journalPrepared, .targetTranscript, .targetChat, .journalCommitted, .sourceCleanup])
    func restartRecoversEveryPromotionCrashStage(stage: LiveArtifactStage) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let fault = LiveArtifactFault(stage: stage)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await fault.check($0) })
        let transcript = await LiveTranscriptStore(identity: f.identity).checkpoint()
        try await writer.saveTranscript(transcript)
        try await writer.saveChat(f.history("Durable original"), revision: 1)
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await writer.bind(to: f.audio) }
        let restart = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        var recovered = try await restart.recover()
        #expect(recovered.chat?.messages.last?.content == "Durable original")
        if stage == .journalPrepared {
            #expect(recovered.audioURL == nil)
            try await restart.bind(to: f.audio)
            recovered = try await restart.recover()
        }
        #expect(recovered.audioURL == f.audio)
        #expect(try await ChatStore().load(from: f.audio.deletingPathExtension().appendingPathExtension("chat.json"))?.messages.last?.content == "Durable original")
        #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
    }

    @Test func answerCompletingDuringPromotionUsesOnlyTheCommittedTarget() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .targetChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        try await writer.saveChat(f.history("Before"), revision: 1)
        let bind = Task { try await writer.bind(to: f.audio) }
        var answer: Task<Void, Error>?
        do {
            try await gate.waitForArrival()
            let completion = Task { try await writer.saveChat(f.history("Completed during binding"), revision: 2) }
            answer = completion
            try await f.eventually { await writer.status().acceptedChatRevision == 2 }
            await gate.release()
            try await bind.value; try await completion.value
            #expect(try await writer.recover().chat?.messages.last?.content == "Completed during binding")
            #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
        } catch {
            bind.cancel(); answer?.cancel(); await gate.release()
            _ = try? await bind.value; _ = try? await answer?.value
            throw error
        }
    }

    @Test(arguments: ["legacy", "foreign", "newer", "corrupt", "unsupported", "reused-media"])
    func targetConflictsKeepBothTheSourceAndExistingTarget(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveChat(f.history("Source"), revision: 1)
        let target = f.audio.deletingPathExtension().appendingPathExtension("chat.json")
        let original: Data
        if kind == "corrupt" { original = Data("{broken".utf8) }
        else {
            var other = f.history("Target")
            other.version = kind == "unsupported" ? 99 : ChatHistory.currentVersion
            if kind != "legacy" {
                other.identity = kind == "foreign" ? .init(recordingID: UUID(), captureSessionID: UUID()) : f.identity
                other.revision = kind == "newer" ? 99 : 1
                other.bindingGeneration = UUID()
            }
            original = try JSONEncoder().encode(other)
        }
        try original.write(to: target)
        if kind == "reused-media" {
            let metadata = RecordingMetadataPayload(recordingID: UUID(), dateISO8601: "fixture", durationSeconds: 1,
                meetingTitle: "Other", masterFileName: f.audio.lastPathComponent, segmentFileNames: [], warnings: [])
            try JSONEncoder().encode(metadata).write(to: f.audio.deletingPathExtension().appendingPathExtension("json"))
        }
        await #expect(throws: (any Error).self) { try await writer.bind(to: f.audio) }
        #expect(try Data(contentsOf: target) == original)
        #expect(FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
    }

    @Test(arguments: [LiveArtifactStage.targetTranscript, .targetChat, .journalCommitted, .sourceCleanup], ["write", "clear", "delete"])
    func aFailedPromotionCannotLoseALaterWriteOrResurrectAClear(stage: LiveArtifactStage, operation: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let fault = LiveArtifactFault(stage: stage)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await fault.check($0) })
        try await writer.saveTranscript(await LiveTranscriptStore(identity: f.identity).checkpoint())
        try await writer.saveChat(f.history("Before"), revision: 1)
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await writer.bind(to: f.audio) }
        if operation == "delete" {
            try await writer.recordDeletionIntent()
            let recovered = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
            #expect(recovered.deleted && recovered.chat == nil)
            await #expect(throws: LiveArtifactError.deleted) { try await writer.retry() }
            return
        }
        let change: @Sendable () async throws -> Void = {
            if operation == "clear" { try await writer.clearChat(revision: 2) }
            else { try await writer.saveChat(f.history("After"), revision: 2) }
        }
        if stage == .sourceCleanup { try await change() }
        else { await #expect(throws: LiveArtifactError.bindingPending) { try await change() } }
        try await writer.retry()
        let recovered = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
        #expect(recovered.audioURL == f.audio && recovered.chat?.revision == 2)
        #expect(operation == "clear" ? recovered.chat?.isEmpty == true : recovered.chat?.messages.last?.content == "After")
        #expect(!FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
    }

    @Test(arguments: ["owner-swap", "reprocessing"])
    func targetOwnershipIsRevalidatedAfterTheSuspendingStage(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .targetChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        try await writer.saveChat(f.history("Keep"), revision: 1)
        let binding = Task { try await writer.bind(to: f.audio) }, claim = UUID()
        defer { RecordingResultMutation.release(audioURL: f.audio, attemptID: claim) }
        do {
            try await gate.waitForArrival()
            if kind == "reprocessing" { try RecordingResultMutation.claim(audioURL: f.audio, attemptID: claim) }
            else {
                let metadata = RecordingMetadataPayload(recordingID: UUID(), dateISO8601: "fixture", durationSeconds: 1,
                    meetingTitle: "Replacement", masterFileName: f.audio.lastPathComponent, segmentFileNames: [], warnings: [])
                try RecordingResultMutation.withTransaction {
                    try JSONEncoder().encode(metadata).write(to: f.audio.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
                }
            }
            await gate.release()
            await #expect(throws: (any Error).self) { try await binding.value }
            #expect(!FileManager.default.fileExists(atPath: f.audio.deletingPathExtension().appendingPathExtension("chat.json").path))
            #expect(FileManager.default.fileExists(atPath: f.session.appendingPathComponent("chat.json").path))
        } catch {
            binding.cancel(); await gate.release(); _ = try? await binding.value
            throw error
        }
    }

    @Test func aPreparedDigestRejectsSameRevisionSourceTampering() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let fault = LiveArtifactFault(stage: .targetChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await fault.check($0) })
        try await writer.saveChat(f.history("Prepared"), revision: 1)
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await writer.bind(to: f.audio) }
        var changed = f.history("Different content at the same revision")
        changed.identity = f.identity; changed.revision = 1; changed.version = ChatHistory.currentVersion
        let bytes = try JSONEncoder().encode(changed)
        try bytes.write(to: f.session.appendingPathComponent("chat.json"), options: .atomic)
        await #expect(throws: (any Error).self) { _ = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover() }
        #expect(try Data(contentsOf: f.session.appendingPathComponent("chat.json")) == bytes)
    }

    @Test func retryCannotReachPastALaterClearBarrier() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let original = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await original.saveChat(f.history("Before"), revision: 1)
        try await original.bind(to: f.audio)
        let gate = LiveArtifactGate(stage: .sourceCleanup)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        let retry = Task { try await writer.retry() }
        var jobs: [Task<Void, Error>] = []
        do {
            try await gate.waitForArrival()
            jobs.append(Task { try await writer.saveChat(f.history("Before clear"), revision: 2) })
            try await f.eventually { await writer.status().acceptedChatRevision == 2 }
            jobs.append(Task { try await writer.clearChat(revision: 3) })
            try await f.eventually { await writer.status().acceptedChatRevision == 3 }
            jobs.append(Task { try await writer.saveChat(f.history("After clear"), revision: 4) })
            try await f.eventually { await writer.status().acceptedChatRevision == 4 }
            await gate.release(); try await retry.value
            // Every admitted interval must finish in order, not become stale
            // because retry inspected a later global accepted slot after await.
            for job in jobs { try await job.value }
            #expect(try await writer.recover().chat?.messages.last?.content == "After clear")
        } catch {
            retry.cancel(); for job in jobs { job.cancel() }
            await gate.release(); _ = try? await retry.value
            for job in jobs { _ = try? await job.value }
            throw error
        }
    }

    @Test func anExplicitlyAbsentChatCanBeCreatedAfterBindingCommits() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.bind(to: f.audio)
        try await writer.saveChat(f.history("First answer after binding"), revision: 1)
        let recovered = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
        #expect(recovered.chat?.messages.first?.content == "First answer after binding" && recovered.audioURL == f.audio)
    }

    @Test func chatAndTranscriptRevisionVectorsAdvanceIndependently() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        let transcript = LiveTranscriptStore(identity: f.identity)
        let epoch = LiveTranscriptFixture().epoch()
        _ = await transcript.beginEpoch(owner: f.identity, epoch: epoch)
        try await writer.saveTranscript(await transcript.checkpoint())
        try await writer.saveChat(f.history("Chat ten"), revision: 10)
        try await writer.bind(to: f.audio)
        _ = await transcript.admit(.init(identity: f.identity, epochID: epoch.id, source: epoch.source, sequence: 0,
            payload: .progress(.init(capturedSampleEnd: 16_000, admittedSampleEnd: 16_000, consumedSampleEnd: 16_000))))
        try await writer.saveTranscript(await transcript.checkpoint())
        let recovered = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
        #expect(recovered.chat?.revision == 10 && recovered.transcript?.revision == 2)
    }

    @Test func retryDoesNotPinAlreadyDurableArtifactsAboveTheQueueByteCap() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceCleanup, initiallyEnabled: false)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        try await writer.saveChat(f.history(String(repeating: "x", count: 4_718_592)), revision: 1)
        let transcript = LiveTranscriptStore(identity: f.identity)
        let helper = LiveTranscriptFixture(), epoch = helper.epoch()
        _ = await transcript.beginEpoch(owner: f.identity, epoch: epoch)
        _ = await transcript.admit(.init(identity: f.identity, epochID: epoch.id, source: .microphone, sequence: 0, payload: helper.progress(72)))
        let block = String(repeating: "y", count: 65_536)
        for index in UInt64(0)..<72 {
            let segment = helper.segment(epoch, index, Int64(index), Int64(index + 1), block)
            _ = await transcript.admit(.init(identity: f.identity, epochID: epoch.id, source: .microphone, sequence: index + 1, payload: .committed(segment)))
        }
        try await writer.saveTranscript(await transcript.checkpoint())
        try await writer.bind(to: f.audio)
        #expect(await writer.status().queuedEncodedBytes == 0)
        await gate.arm()
        let retry = Task { try await writer.retry() }
        do {
            try await gate.waitForArrival()
            #expect(await writer.status().queuedEncodedBytes <= 8 * 1_024 * 1_024)
            #expect(await writer.status().retainedPayloads == 0)
            await gate.release(); try await retry.value
        } catch {
            retry.cancel(); await gate.release(); _ = try? await retry.value
            throw error
        }
    }
}
}

private actor LiveArtifactBindingStageProbe {
    private(set) var preparedCount = 0
    func record(_ stage: LiveArtifactStage) { if stage == .journalPrepared { preparedCount += 1 } }
}
