import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Calendar participants in processing")
struct ProcessingCalendarParticipantsTests {
    private actor FetchCounter {
        var calls = 0
        func add() { calls += 1 }
    }

    @Test("Pending enrichment uses frozen effort and terminal recovery reuses the result")
    func pendingAndTerminalRecovery() async throws {
        let config = CalendarCLIConfig.unnormalized(timeoutSeconds: 30,
            mailboxEmail: "ada@example.com")
        let scope = CalendarCLIScope(config: config)
        let selection = CalendarParticipantSelection(scope: scope,
            entry: CalendarCLICacheTests.entry())
        let frozen = CalendarParticipantRequestConfiguration(config: config, scope: scope)
        let counter = FetchCounter()
        let loaded = CalendarCLICacheTests.entry(state: .loaded, fetchedAt: Date(),
            attendees: [.init(name: "Alex", email: "alex@example.com")])
        let pipeline = ProcessingPipeline()
        let result = try await pipeline.enrichCalendarParticipants(
            prior: .init(selection: selection), frozenConfiguration: frozen,
            currentConfiguration: config.updating(effort: .high), fetch: { _, effective in
                #expect(effective.effort == config.effort)
                await counter.add()
                return loaded
            })
        #expect(result.state == .completed)
        #expect(result.resolvedEntry?.event.attendees.count == 1)
        let reused = try await pipeline.enrichCalendarParticipants(
            prior: result, frozenConfiguration: frozen, currentConfiguration: config,
            fetch: { _, _ in await counter.add(); return loaded })
        #expect(reused == result)
        #expect(await counter.calls == 1)
    }

    @Test("Never policy, changed mailbox, and terminal warning do not fetch")
    func unsafeRecoveryIsWarningWithoutRead() async throws {
        let config = CalendarCLIConfig.unnormalized(timeoutSeconds: 30,
            mailboxEmail: "ada@example.com")
        let scope = CalendarCLIScope(config: config)
        let selection = CalendarParticipantSelection(scope: scope,
            entry: CalendarCLICacheTests.entry())
        let frozen = CalendarParticipantRequestConfiguration(config: config, scope: scope)
        let counter = FetchCounter()
        let pipeline = ProcessingPipeline()
        for current in [config.updating(attendeePolicy: .never),
                        config.updating(mailboxEmail: "other@example.com")] {
            let warned = try await pipeline.enrichCalendarParticipants(
                prior: .init(selection: selection), frozenConfiguration: frozen,
                currentConfiguration: current, fetch: { _, _ in
                    await counter.add()
                    return selection.entry
                })
            #expect(warned.state == .warning)
            let reused = try await pipeline.enrichCalendarParticipants(
                prior: warned, frozenConfiguration: frozen, currentConfiguration: config,
                fetch: { _, _ in await counter.add(); return selection.entry })
            #expect(reused.state == .warning)
        }
        #expect(await counter.calls == 0)
    }

    @Test("Connector failure is terminal for automatic recovery")
    func failureIsTerminal() async throws {
        let config = CalendarCLIConfig.unnormalized(timeoutSeconds: 30,
            mailboxEmail: "ada@example.com")
        let selection = CalendarParticipantSelection(scope: CalendarCLIScope(config: config),
            entry: CalendarCLICacheTests.entry())
        let frozen = CalendarParticipantRequestConfiguration(config: config, scope: selection.scope)
        let counter = FetchCounter()
        let pipeline = ProcessingPipeline()
        let warned = try await pipeline.enrichCalendarParticipants(prior: .init(selection: selection),
            frozenConfiguration: frozen, currentConfiguration: config, fetch: { _, _ in
                await counter.add()
                throw CalendarCLIServiceError.refreshFailed
            })
        #expect(warned.state == .warning)
        let reused = try await pipeline.enrichCalendarParticipants(prior: warned,
            frozenConfiguration: frozen, currentConfiguration: config, fetch: { _, _ in
                await counter.add()
                return selection.entry
            })
        #expect(reused.state == .warning)
        #expect(await counter.calls == 1)
    }

    @Test("A reduced cap returns a warning without publishing attendees")
    func reducedCap() async throws {
        let config = CalendarCLIConfig.unnormalized(timeoutSeconds: 30,
            mailboxEmail: "ada@example.com", maxAttendees: 20)
        let selection = CalendarParticipantSelection(scope: CalendarCLIScope(config: config),
            entry: CalendarCLICacheTests.entry())
        let frozen = CalendarParticipantRequestConfiguration(config: config, scope: selection.scope)
        let loaded = CalendarCLICacheTests.entry(state: .loaded, fetchedAt: Date(),
            attendees: [.init(name: "Alex", email: "alex@example.com"),
                        .init(name: "Sam", email: "sam@example.com")])
        let result = try await ProcessingPipeline().enrichCalendarParticipants(
            prior: .init(selection: selection), frozenConfiguration: frozen,
            currentConfiguration: config.updating(maxAttendees: 1), fetch: { _, _ in loaded })
        #expect(result.state == .warning)
        #expect(result.resolvedEntry == nil)
    }
    private actor Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private actor Audit {
        var calls: [String] = []
        var participantTask: Task<Void, Never>?
        func add(_ value: String) { calls.append(value) }
        func start(_ gate: Gate) {
            calls.append("participants-start")
            participantTask = Task { await gate.wait() }
        }
        func finish() async {
            await participantTask?.value
            calls.append("participants-finish")
        }
        func waitFor(_ value: String) async -> Bool {
            for _ in 0..<100 {
                if calls.contains(value) { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
    }

    private func steps(_ audit: Audit, gate: Gate) -> ProcessingPipeline.PreparationSteps {
        .init(waitForCalendar: { await audit.add("calendar") },
              finalize: { await audit.add("finalize") },
              finalizationCommitted: {}, meetingContext: {}, prewarm: {},
              loadTranscript: { nil },
              transcribe: {
                  await audit.add("transcribe")
                  return .init(transcription: TranscriptionResult(text: "Hello", segments: []),
                               model: nil, audioDuration: 1, spellCorrectionTime: nil)
              },
              publishTranscript: { _, _ in }, saveTranscript: { _ in },
              checkpoint: { await audit.add("checkpoint:\($0.rawValue)") },
              retireQueue: {}, transcriptCommitted: { _, _ in },
              speakers: { _, _ in await audit.add("speakers"); return false },
              startParticipants: { await audit.start(gate) },
              finishParticipants: { await audit.finish() })
    }

    @Test("Transcription overlaps roster loading, while speakers wait for it")
    func transcriptionOverlapsParticipants() async throws {
        let audit = Audit()
        let gate = Gate()
        let input = steps(audit, gate: gate)
        let task = Task { try await ProcessingPipeline().prepareWorkflow(transcribe: true, steps: input) }
        #expect(await audit.waitFor("transcribe"))
        #expect(!(await audit.calls).contains("speakers"))
        await gate.release()
        _ = try await task.value
        let calls = await audit.calls
        #expect(calls.firstIndex(of: "participants-start")! < calls.firstIndex(of: "transcribe")!)
        #expect(calls.firstIndex(of: "participants-finish")! < calls.firstIndex(of: "speakers")!)
    }

    @Test("A metadata-only job joins roster work before export checkpoint")
    func noTranscriptionStillJoins() async throws {
        let audit = Audit()
        let gate = Gate()
        let input = steps(audit, gate: gate)
        let task = Task { try await ProcessingPipeline().prepareWorkflow(transcribe: false, steps: input) }
        #expect(await audit.waitFor("finalize"))
        #expect(!(await audit.calls).contains("checkpoint:speakerReviewCompleted"))
        await gate.release()
        _ = try await task.value
        let calls = await audit.calls
        #expect(calls.firstIndex(of: "participants-finish")! < calls.firstIndex(of: "checkpoint:speakerReviewCompleted")!)
    }
}
