import Foundation
import Testing
import dBriefWire
@testable import dBrief

extension LiveArtifactDurabilityTests {
@MainActor @Suite struct LiveHistoryRetentionTests {
    private func old(_ urls: [URL]) throws {
        for url in urls { try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: url.path) }
    }
    private func source(_ f: LiveArtifactFixture) -> LiveTranscriptArtifact {
        .init(identity: f.identity, revision: 7, legacy: [.init(.init(start: 0, end: 1, text: "Exact saved source", speaker: "You"))], captureClosed: true)
    }
    private func answer(_ f: LiveArtifactFixture) throws -> ChatHistory {
        let id = UUID(), text = "Saved partial answer [[dbrief:1]]"
        let context = try TranscriptContextBuilder.build(snapshot: source(f).legacyContext(),
            route: .init(engine: "fixture", endpointID: nil, provider: nil, origin: nil, model: nil),
            budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256), language: .matchInput,
            question: "What?", history: [], answerID: id)
        return .init(messages: [.init(id: id, role: .assistant, content: text, basis: context.basis, outcome: .streaming,
            referenceResolution: ChatReferenceParser.resolve(text, basis: context.basis))])
    }

    @Test(arguments: [false, true]) func portableExportPreservesExactNativeOrAppAndHistoricalChat(native: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        if native { try await writer.saveTranscript(await LiveTranscriptStore(identity: f.identity).checkpoint()) }
        else { try await writer.saveTranscript(source(f)) }
        try await writer.saveChat(answer(f), revision: 9); try await writer.bind(to: f.audio)
        let paths = [f.session.appendingPathComponent("binding.json"), f.audio.deletingPathExtension().appendingPathExtension("live-binding.json"),
            f.audio.deletingPathExtension().appendingPathExtension("live-transcript.json"), f.audio.deletingPathExtension().appendingPathExtension("chat.json")]
        let bytes = try paths.map { try Data(contentsOf: $0) }, stamps = try paths.map { try RecordingDeletionAuthority.Stamp.read($0) }
        let budget = LiveRecordingPayloadBudget(ownerLimit: 8), registry = LiveRecordingSessionRegistry(artifactRoot: f.root, payloadBudget: budget)
        var hydrations = 0; registry.onHydration = { _ in hydrations += 1 }
        try await registry.discover(); let baseline = budget.reservedBytes
        var snapshot: LiveHistoryExportSnapshot? = try await registry.prepareHistoryExport(recordingID: f.identity.recordingID, audioURL: f.audio)
        let value = try JSONDecoder().decode(LiveHistoryExport.self, from: #require(snapshot?.data))
        #expect(value.version == 1 && value.identity == f.identity && value.sourceAvailable)
        #expect(value.chat == (try JSONDecoder().decode(ChatHistory.self, from: bytes[3])))
        #expect(value.chat?.messages.first?.outcome == .streaming)
        let saved = try LiveTranscriptArtifactCodec.decode(bytes[2])
        #expect(value.native == (native ? saved.native : nil) && value.app == saved.app)
        #expect(hydrations == 0 && registry.entry(recordingID: f.identity.recordingID) == nil)
        #expect(try paths.map { try Data(contentsOf: $0) } == bytes)
        #expect(try paths.map { try RecordingDeletionAuthority.Stamp.read($0) } == stamps)
        #expect(!String(decoding: try #require(snapshot?.data), as: UTF8.self).contains(f.root.path))
        #expect(budget.reservedBytes == baseline + 32 * 1_024 * 1_024)
        snapshot = nil; #expect(budget.reservedBytes == baseline)
    }

    @Test func exportCannotRollForwardAPreparedBindingOrNormalizeSavedAnswers() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .targetChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await gate.enter($0) })
        try await writer.saveTranscript(source(f)); try await writer.saveChat(answer(f), revision: 9)
        let bind = Task { try await writer.bind(to: f.audio) }
        do {
            try await gate.waitForArrival()
            let paths = [f.session.appendingPathComponent("binding.json"), f.session.appendingPathComponent("live-transcript.json"), f.session.appendingPathComponent("chat.json")]
            let before = try paths.map { try Data(contentsOf: $0) }
            let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
            await #expect(throws: LiveArtifactError.bindingPending) { _ = try await registry.prepareHistoryExport(recordingID: f.identity.recordingID, audioURL: f.audio) }
            #expect(try paths.map { try Data(contentsOf: $0) } == before)
            #expect(!FileManager.default.fileExists(atPath: f.audio.deletingPathExtension().appendingPathExtension("live-binding.json").path))
            await gate.release(); try await bind.value
        } catch { bind.cancel(); await gate.release(); _ = try? await bind.value; throw error }
    }

    @Test(arguments: [false, true]) func aHeldColdExportIsRevokedWithoutReleasingItsPayloadLeaseEarly(cancel: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveTranscript(source(f)); try await writer.saveChat(answer(f), revision: 9); try await writer.bind(to: f.audio)
        let gate = LiveArtifactGate(stage: .exportSnapshot), budget = LiveRecordingPayloadBudget(ownerLimit: 8)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) }, payloadBudget: budget)
        try await registry.discover(); let baseline = budget.reservedBytes
        let export = Task { try await registry.prepareHistoryExport(recordingID: f.identity.recordingID, audioURL: f.audio) }
        var phase: LiveRecordingSessionRegistry.Replacement?
        do {
            try await gate.waitForArrival()
            if cancel { export.cancel() }
            else { phase = try registry.beginReplacement(recordingID: f.identity.recordingID, audioURL: f.audio) }
            #expect(budget.reservedBytes == baseline + 32 * 1_024 * 1_024)
            await gate.release()
            await #expect(throws: CancellationError.self) { _ = try await export.value }
            if let phase { registry.abandonReplacement(phase) }
            #expect(budget.reservedBytes == baseline && registry.entry(recordingID: f.identity.recordingID) == nil)
        } catch { export.cancel(); await gate.release(); _ = try? await export.value; if let phase { registry.abandonReplacement(phase) }; throw error }
    }

    @Test(arguments: ["foreign", "unsupported", "oversized"]) func exportNeverAdoptsUnknownPayloads(kind: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try FileManager.default.createDirectory(at: f.session, withIntermediateDirectories: true)
        var history = try answer(f); history.identity = f.identity; history.revision = 9
        if kind == "foreign" { history.identity = .init(recordingID: f.identity.recordingID, captureSessionID: UUID()) }
        if kind == "unsupported" { history.version = 99 }
        let bytes = kind == "oversized" ? Data(repeating: 32, count: LiveRecordingArtifactOwner.chatHistoryLimit + 1) : try JSONEncoder().encode(history)
        let path = f.session.appendingPathComponent("chat.json"); try bytes.write(to: path)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root)
        await #expect(throws: (any Error).self) { _ = try await registry.prepareHistoryExport(recordingID: f.identity.recordingID, audioURL: f.audio) }
        #expect(try Data(contentsOf: path) == bytes && registry.entry(recordingID: f.identity.recordingID) == nil)
    }

    @Test func partialRetentionAcceptsOnlyTheRecordedPhysicalRewrite() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let fault = LiveArtifactFault(stage: .retentionChat)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root, beforeStage: { try await fault.check($0) })
        try await writer.saveTranscript(source(f)); try await writer.saveChat(answer(f), revision: 9)
        let transcript = f.session.appendingPathComponent("live-transcript.json"), chat = f.session.appendingPathComponent("chat.json")
        try old([transcript, chat])
        let receipt = try #require(try await writer.commitRetention(olderThan: Date().addingTimeInterval(-7 * 86_400),
            authority: .init(audioURL: f.audio, expectedRecordingID: f.identity.recordingID), conventional: [], linkedMarkdown: nil))
        await #expect(throws: LiveArtifactFixtureFailure.injected) { try await writer.cleanupRetention(receipt) }
        let rewritten = try Data(contentsOf: transcript), beforeChat = try Data(contentsOf: chat)
        try rewritten.write(to: transcript, options: .atomic)
        await #expect(throws: LiveArtifactError.wrongOwner) { _ = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover() }
        #expect(try Data(contentsOf: transcript) == rewritten && Data(contentsOf: chat) == beforeChat)
    }

    @Test func sourceRetirementStaysStickyAcrossLaterChatAndConventionalRetention() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        try await writer.saveTranscript(source(f)); try await writer.saveChat(answer(f), revision: 9)
        let transcript = f.session.appendingPathComponent("live-transcript.json"), chat = f.session.appendingPathComponent("chat.json")
        try old([transcript])
        let authority = try RecordingDeletionAuthority(audioURL: f.audio, expectedRecordingID: f.identity.recordingID)
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        try await writer.cleanupRetention(#require(try await writer.commitRetention(olderThan: cutoff, authority: authority, conventional: [], linkedMarkdown: nil)))
        let fresh = LiveSessionArtifactStore(identity: f.identity, rootURL: f.root)
        #expect(try await fresh.recover().historyRetained)
        let script = f.audio.deletingPathExtension().appendingPathExtension("md")
        try Data("Conventional markdown, not JSON".utf8).write(to: script); try old([chat, script])
        let second = try #require(try await fresh.commitRetention(olderThan: cutoff, authority: authority,
            conventional: [try .init(script)], linkedMarkdown: nil))
        try await fresh.cleanupRetention(second)
        let restored = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
        #expect(restored.historyRetained && restored.appTranscript?.sourceUnavailable == true && restored.chat?.messages.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: script.path) && FileManager.default.fileExists(atPath: f.audio.path))
    }
}
}
