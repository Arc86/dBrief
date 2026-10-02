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
