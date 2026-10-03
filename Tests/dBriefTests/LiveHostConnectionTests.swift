import Foundation
import Testing
import dBriefWire
@testable import dBrief

private struct LiveHostFixture: Sendable {
    let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
    let epochID = UUID()
    var scope: LiveLaneScope { .init(identity: identity,source: .microphone,epochID: epochID) }
    var begin: LiveSessionBegin { .init(identity: identity,configuration: .init(language: .auto,modelDirectory: "/private/models"),epochs: [
        .init(id: epochID,source: .microphone,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)]) }
    func connection(_ mode: String = "live-tail", role: MLHostRole = .live) -> MLHostConnection {
        .init(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),supportBase: URL(fileURLWithPath: "/private/tmp"),environment: ["STUB_MODE":mode],role: role)
    }
}

@Suite struct LiveHostConnectionTests {
    @Test func shuttingDownNeverUsedLiveConnectionPreventsDelayedBeginBeforeAnyLaunch() async throws {
        let f = LiveHostFixture()
        // If the terminal role guard permits launch, this nonexistent binary
        // would fail differently from the required protocolViolation.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("never-launch-live-\(UUID())")
        let live = MLHostConnection(binaryURL: missing,supportBase: FileManager.default.temporaryDirectory,role: .live)
        await live.shutdownLiveAndWaitForExit()
        await #expect(throws: MLHostError.protocolViolation) { _ = try await live.beginLive(f.begin) }
        let ordinary = f.connection("echo",role: .ordinary)
        do {
            let event = try await ordinary.call(.transcribe(path: "/fixture/synthetic.m4a",initialPrompt: nil,config: .default,safeMode: false,unloadAfter: true))
            #expect({ if case .transcriptionResult(let result) = event { result.text == "echo" } else { false } }())
        } catch { await ordinary.shutdown(); throw error }
        await ordinary.shutdown()
    }

    @Test func ASROnlyStubRejectsConfiguredVADWithoutAnyReadiness() async throws {
        let f = LiveHostFixture(), connection = f.connection()
        let vad = LiveVADConfiguration(identity: .init(modelRevision: "fixture-silero",modelFingerprint: String(repeating: "a",count: 64),
            runtimeRevision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f"),modelPath: "/fixture/silero.mlmodelc")
        let stream = try await connection.beginLive(.init(identity: f.identity,configuration: f.begin.configuration,epochs: f.begin.epochs,vad: vad))
        defer { Task { await connection.shutdown() } }
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: LiveProtocolError.unavailable) { _ = try await iterator.next() }
    }

    @Test func terminalClosesAdmissionBeforeItsBufferedCompletionCanPublish() async throws {
        let f = LiveHostFixture()
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("live-terminal-gate-\(UUID()).flag")
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),supportBase: URL(fileURLWithPath: "/private/tmp"),environment: ["STUB_MODE":"live-terminal-admission-gate","STUB_FLAG_1":gate.path],role: .live)
        defer {
            try? Data().write(to: gate)
            Task {
                await connection.shutdown()
                try? FileManager.default.removeItem(at: gate)
            }
        }
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        let command = Task { try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .pause))) }
        let marker = try #require(try await iterator.next())
        #expect({ if case .lane(let e) = marker, case .progress = e.payload { true } else { false } }())
        // Cancel's own reply follows terminal on the wire; its return proves
        // terminal handling, without needing a post-terminal lane marker.
        #expect(try await connection.sendLive(.cancel(f.identity)) == .accepted)
        await #expect(throws: MLHostError.protocolViolation) {
            _ = try await connection.sendLive(.packet(try .init(scope: f.scope,sequence: 0,startSample: 0,samples: [1])))
        }
        try Data().write(to: gate)
        #expect(try await command.value == .accepted)
        let ack = try #require(try await iterator.next())
        #expect({ if case .lane(let e) = ack, case .barrierCompleted(_, .pause,0) = e.payload { true } else { false } }())
        #expect(try await iterator.next() == .finished(f.identity))
        #expect(try await iterator.next() == nil)
        await connection.shutdown()
    }

    @Test(arguments: ["live-wrong-barrier-id", "live-wrong-barrier-kind", "live-wrong-barrier-end", "live-duplicate-barrier", "live-unsolicited-barrier", "live-completion-after-rejection", "live-rejected-after-completion", "live-barrier-buffer-overflow", "live-evidence-after-held-terminal"])
    func invalidBarrierReceiptsFailTheTransport(mode: String) async throws {
        let f = LiveHostFixture(), connection = f.connection(mode)
        defer { Task { await connection.shutdown() } }
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        if mode != "live-unsolicited-barrier" {
            do {
                let reply = try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .pause)))
                #expect(reply == (mode == "live-completion-after-rejection" ? .rejected(.unavailable) : .accepted))
            } catch {
                #expect(error as? MLHostError == .protocolViolation)
            }
        }
        var failure: MLHostError?
        do { while try await iterator.next() != nil {} } catch { failure = error as? MLHostError }
        #expect(failure == .protocolViolation)
        await connection.shutdown()
    }

    @Test func contradictoryTerminalBeforePendingReplyFailsTheCommand() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-double-terminal-before-reply")
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        await #expect(throws: MLHostError.protocolViolation) {
            _ = try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .pause)))
        }
        await connection.shutdown()
    }

    @Test(arguments: [false,true])
    func preReplyCompletionProofSurvivesAcceptedOuterRetirement(accepted: Bool) async throws {
        let f = LiveHostFixture(), connection = f.connection("live-retire-before-old-reply-\(accepted ? "accepted" : "rejected")")
        let system = LiveEpoch(id: UUID(),source: .system,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)
        let begin = LiveSessionBegin(identity: f.identity,configuration: f.begin.configuration,epochs: f.begin.epochs + [system])
        let stream = try await connection.beginLive(begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<2 { try #require(try await iterator.next() != nil) }
        let command = Task { try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .pause))) }
        // A healthy-source marker follows the held mic ACK in wire order. It
        // proves ingestion without timing assumptions or publishing that ACK.
        let marker = try #require(try await iterator.next())
        #expect({ if case .lane(let e) = marker, e.scope.source == .system, case .progress = e.payload { true } else { false } }())
        #expect(try await connection.sendLive(.cut(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,reason: .engineRestart)) == .accepted)
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)
        _ = try? await connection.sendLive(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch))
        if accepted {
            #expect(try await command.value == .accepted)
            #expect(try await connection.sendLive(.cancel(f.identity)) == .accepted)
            var oldCompletions = 0
            while let event = try await iterator.next() {
                if case .lane(let e) = event, e.scope == f.scope, case .barrierCompleted = e.payload { oldCompletions += 1 }
            }
            #expect(oldCompletions == 0)
        } else {
            await #expect(throws: MLHostError.protocolViolation) { _ = try await command.value }
            await #expect(throws: MLHostError.protocolViolation) { while try await iterator.next() != nil {} }
        }
        await connection.shutdown()
    }

    @Test func staleBarrierRequestsCannotExhaustTheHealthyReplacement() async throws {
        let f = LiveHostFixture(), connection = f.connection()
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(4))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        #expect(try await connection.sendLive(.cut(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,reason: .engineRestart)) == .accepted)
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await connection.sendLive(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch)) == .accepted)
        let stale = LiveFinishBarrier(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .pause)
        for _ in 0..<129 {
            await #expect(throws: LiveProtocolError.staleScope) { _ = try await connection.sendLive(.barrier(stale)) }
        }
        let scope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: epoch.id)
        #expect(try await connection.sendLive(.barrier(.init(scope: scope,nextPacketSequence: 0,sampleEnd: 0,kind: .finish))) == .accepted)
        var newAcknowledgements = 0
        while let event = try await iterator.next() {
            if case .lane(let e) = event, e.scope == scope, case .barrierCompleted = e.payload { newAcknowledgements += 1 }
        }
        #expect(newAcknowledgements == 1)
        await connection.shutdown()
    }

    @Test(arguments: [LiveFinishBarrier.Kind.pause, .finish])
    func needsReplacementBeforeClosingAckPreservesTheExactReceipt(kind: LiveFinishBarrier.Kind) async throws {
        let f = LiveHostFixture(), connection = f.connection("live-needs-before-barrier-reply")
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        #expect(try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: kind))) == .accepted)
        if kind == .pause { #expect(try await connection.sendLive(.cancel(f.identity)) == .accepted) }
        var payloads: [LiveLaneEvent.Payload] = []
        while let event = try await iterator.next() { if case .lane(let e) = event { payloads.append(e.payload) } }
        try #require(payloads.count == (kind == .finish ? 3 : 2))
        #expect(payloads[0] == .needsEpochReplacement)
        #expect({ if case .barrierCompleted(_,let ackKind,0) = payloads[1] { ackKind == kind } else { false } }())
        await connection.shutdown()
    }

    @Test func retiredEpochFramesAreIgnoredAsAWholeAfterTheReplacementReply() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-retired-epoch-frames")
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        #expect(try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .pause))) == .accepted)
        #expect(try await connection.sendLive(.cut(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,reason: .engineRestart)) == .accepted)
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await connection.sendLive(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch)) == .accepted)
        let scope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: epoch.id)
        #expect(try await connection.sendLive(.barrier(.init(scope: scope,nextPacketSequence: 0,sampleEnd: 0,kind: .finish))) == .accepted)
        var lanes: [LiveLaneEvent] = []
        while let event = try await iterator.next() { if case .lane(let e) = event { lanes.append(e) } }
        #expect(lanes.filter { $0.scope == f.scope }.map(\.payload) == [.needsEpochReplacement])
        #expect(lanes.filter { $0.scope == scope }.map(\.sequence) == [0,1,2])
        await connection.shutdown()
    }

    @Test func anOldRequestUUIDCannotClaimANewEpochCompletion() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-old-id-new-epoch")
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        #expect(try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .pause))) == .accepted)
        #expect(try await connection.sendLive(.cut(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,reason: .engineRestart)) == .accepted)
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)
        _ = try? await connection.sendLive(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch))
        await #expect(throws: MLHostError.protocolViolation) { while try await iterator.next() != nil {} }
        await connection.shutdown()
    }

    @Test func barrierCompletionBeforeReplyPreservesTerminalOrdering() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-barrier-before-reply")
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        #expect(try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .finish))) == .accepted)
        var events: [LiveSessionEvent] = []
        while let event = try await iterator.next() { events.append(event) }
        #expect(events.count == 3)
        if events.count == 3 {
            #expect({ if case .lane(let e) = events[0], case .barrierCompleted(_, .finish,0) = e.payload { true } else { false } }())
            #expect({ if case .lane(let e) = events[1], case .closed(0) = e.payload { true } else { false } }())
            #expect(events[2] == .finished(f.identity))
        }
        await connection.shutdown()
    }

    @Test func rejectedBarrierDoesNotConsumeTheLaterExactReceipt() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-reject-first-barrier")
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        let barrier = LiveFinishBarrier(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .finish)
        #expect(try await connection.sendLive(.barrier(barrier)) == .rejected(.unavailable))
        #expect(try await connection.sendLive(.barrier(barrier)) == .accepted)
        var acknowledgements = 0
        while let event = try await iterator.next() {
            if case .lane(let e) = event, case .barrierCompleted = e.payload { acknowledgements += 1 }
        }
        #expect(acknowledgements == 1)
        await connection.shutdown()
    }

    @Test func exactCutReceiptPreservesNumberingAndCannotAcknowledgeTheReplacementEpoch() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-late-barrier-after-cut")
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() != nil)
        #expect(try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .pause))) == .accepted)
        #expect(try await connection.sendLive(.cut(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,reason: .engineRestart)) == .accepted)
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await connection.sendLive(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch)) == .accepted)
        let scope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: epoch.id)
        #expect(try await connection.sendLive(.barrier(.init(scope: scope,nextPacketSequence: 0,sampleEnd: 0,kind: .finish))) == .accepted)
        var acknowledgements: [LiveLaneScope] = []
        var sequences: [UUID: UInt64] = [f.epochID: 1]
        while let event = try await iterator.next() {
            if case .lane(let e) = event {
                #expect(e.sequence == sequences[e.scope.epochID,default: 0])
                sequences[e.scope.epochID] = e.sequence + 1
                if case .barrierCompleted = e.payload { acknowledgements.append(e.scope) }
            }
        }
        #expect(acknowledgements == [f.scope,scope])
        await connection.shutdown()
    }

    @Test func dedicatedStreamPreservesCommandCorrelationAndTail() async throws {
        let f = LiveHostFixture(), connection = f.connection()
        let stream = try await connection.beginLive(f.begin)
        var iterator = stream.makeAsyncIterator()
        guard let initial = try await iterator.next() else { Issue.record("no ready"); return }
        guard case .lane(let ready) = initial, case .ready = ready.payload else { Issue.record("no ready event"); return }
        #expect(ready.scope == f.scope)
        let packet = try LiveAudioPacket(scope: f.scope,sequence: 0,startSample: 0,samples: [1,2,3])
        #expect(try await connection.sendLive(.packet(packet)) == .accepted)
        await connection.armLiveDeadline(.seconds(2))
        #expect(try await connection.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 1,sampleEnd: 3,kind: .finish))) == .accepted)
        var events = [initial]
        while let event = try await iterator.next() { events.append(event) }
        let segments = events.compactMap { if case .lane(let e) = $0, case .committed(let s) = e.payload { s } else { nil } }
        #expect(segments.count == 1 && segments.first?.range.samples == .init(start: 0,end: 3))
        #expect(events.contains(.finished(f.identity)))
        await connection.shutdown()
    }
    @Test func ordinaryConnectionCannotStartLiveAndLiveCannotCallChat() async {
        let f = LiveHostFixture(), ordinary = f.connection(role: .ordinary), live = f.connection()
        await #expect(throws: MLHostError.protocolViolation) { _ = try await ordinary.beginLive(f.begin) }
        await #expect(throws: MLHostError.protocolViolation) { _ = try await live.call(.chatStream(systemPrompt: "system",userMessage: "question")) }
        await ordinary.shutdown(); await live.shutdown()
    }
    @Test func deadlineKillsOnlyLiveWhileAnOrdinaryCallStillWorks() async throws {
        let f = LiveHostFixture(), live = f.connection("live-unresponsive-finish")
        let completionFlag = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("live-chat-isolation-\(UUID()).flag")
        defer { try? FileManager.default.removeItem(at: completionFlag) }
        let ordinary = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),supportBase: URL(fileURLWithPath: "/private/tmp"),
            environment: ["STUB_MODE":"chat-across-live-stop","STUB_FLAG_1":completionFlag.path])
        let stream = try await live.beginLive(f.begin)
        var iterator = stream.makeAsyncIterator()
        guard try await iterator.next() != nil else { Issue.record("no ready"); return }
        let chat = await ordinary.stream(.chatStream(systemPrompt: "Fixture",userMessage: "Fixture"))
        var chatIterator = chat.makeAsyncIterator()
        #expect(try await chatIterator.next() == "Fixture started")
        let started = ContinuousClock.now
        await live.armLiveDeadline(.milliseconds(100))
        #expect(try await live.sendLive(.barrier(.init(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,kind: .finish))) == .accepted)
        var error: MLHostError?
        do { while try await iterator.next() != nil {} } catch let e as MLHostError { error = e }
        #expect(error == .liveDeadline && started.duration(to: .now) < .seconds(2))
        try Data().write(to: completionFlag)
        #expect(try await chatIterator.next() == "Fixture completed")
        #expect(try await chatIterator.next() == nil)
        await ordinary.shutdown(); await live.shutdown()
    }
    @Test(arguments: ["live-init-failure","live-wrong-scope","live-oversized"])
    func malformedOrFailedSessionCannotRemainReady(mode: String) async throws {
        let f = LiveHostFixture(), connection = f.connection(mode)
        let stream = try await connection.beginLive(f.begin)
        await connection.armLiveDeadline(.seconds(2))
        var failed = false
        do { for try await _ in stream {} } catch { failed = true }
        #expect(failed)
        await connection.shutdown()
    }
    @Test func crashTerminatesTheSessionInsteadOfRelaunchingIntoOldEpoch() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-crash")
        let stream = try await connection.beginLive(f.begin)
        var iterator = stream.makeAsyncIterator()
        guard try await iterator.next() != nil else { Issue.record("no ready"); return }
        let packet = try LiveAudioPacket(scope: f.scope,sequence: 0,startSample: 0,samples: [1])
        await #expect(throws: MLHostError.helperCrashed) { _ = try await connection.sendLive(.packet(packet)) }
        var error: MLHostError?
        do { while try await iterator.next() != nil {} } catch let e as MLHostError { error = e }
        #expect(error == .helperCrashed)
        await connection.shutdown()
    }
    @Test func deadlineStillFiresWhileInputPipeAndCommandsAreBlocked() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-read-stall")
        let stream = try await connection.beginLive(f.begin)
        var iterator = stream.makeAsyncIterator()
        guard try await iterator.next() != nil else { Issue.record("no ready"); return }
        let started = ContinuousClock.now
        await connection.armLiveDeadline(.milliseconds(150))
        let errors = await withTaskGroup(of: MLHostError?.self, returning: [MLHostError?].self) { group in
            for i in 0..<16 {
                group.addTask {
                    do {
                        let packet = try LiveAudioPacket(scope: f.scope,sequence: UInt64(i),startSample: Int64(i*3200),samples: Array(repeating: 1,count: 3200))
                        _ = try await connection.sendLive(.packet(packet)); return nil
                    } catch { return error as? MLHostError }
                }
            }
            var results: [MLHostError?] = []
            for await error in group { results.append(error) }
            return results
        }
        #expect(errors.count == 16 && errors.allSatisfy { $0 == .liveDeadline })
        #expect(started.duration(to: .now) < .seconds(2))
        await #expect(throws: MLHostError.liveDeadline) { while try await iterator.next() != nil {} }
        await connection.shutdown()
    }

    @Test func terminalSessionEventBeforeCommandAckDoesNotLoseItsReply() async throws {
        let f = LiveHostFixture(), connection = f.connection("live-terminal-before-ack")
        let stream = try await connection.beginLive(f.begin)
        var iterator = stream.makeAsyncIterator()
        guard try await iterator.next() != nil else { Issue.record("no ready"); return }
        await connection.armLiveDeadline(.seconds(2))
        #expect(try await connection.sendLive(.cancel(f.identity)) == .accepted)
        #expect(try await iterator.next() == .finished(f.identity))
        #expect(try await iterator.next() == nil)
        await connection.shutdown()
    }

    @Test func explicitReplacementAcceptsOnlyTheNewEpochAfterItsAck() async throws {
        let f = LiveHostFixture(), connection = f.connection(), newID = UUID()
        let stream = try await connection.beginLive(f.begin)
        var iterator = stream.makeAsyncIterator()
        guard try await iterator.next() != nil else { Issue.record("no ready"); return }
        #expect(try await connection.sendLive(.cut(scope: f.scope,nextPacketSequence: 0,sampleEnd: 0,reason: .engineRestart)) == .accepted)
        let epoch = LiveEpoch(id: newID,source: .microphone,engineRevision: "nemotron",language: "auto",meetingOriginNanoseconds: nil)
        #expect(try await connection.sendLive(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch)) == .accepted)
        var ready = false
        for _ in 0..<4 {
            guard let event = try await iterator.next() else { break }
            if case .lane(let lane) = event, lane.scope.epochID == newID, case .ready = lane.payload { ready = true; break }
        }
        #expect(ready)
        await #expect(throws: LiveProtocolError.staleScope) {
            _ = try await connection.sendLive(.replaceEpoch(identity: f.identity,oldEpochID: f.epochID,epoch: epoch))
        }
        await connection.shutdown()
    }

}
