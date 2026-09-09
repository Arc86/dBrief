import Foundation
import Testing
@testable import dBrief

@Suite("Processing delivery handoff")
struct ProcessingDeliveryTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func batch(_ root: URL) -> IntegrationDeliveryBatch {
        .init(id: UUID(), recordingID: UUID(), createdAt: .now,
              bundle: .init(title: "Fixture", createdAt: .now, durationSeconds: 1,
                            audioFileURL: root.appendingPathComponent("audio.wav"), transcript: "Text", summary: nil,
                            actionItems: [], tags: [], sentiment: nil, markdown: nil, calendarEvent: nil),
              deliveries: [.init(id: UUID(), destination: .webhook, configurationDigest: "fixture")])
    }
    private actor Audit {
        var events: [String] = []
        var owns = true
        func relinquish() { owns = false }
        func add(_ value: String) { events.append(value) }
    }

    @Test func heldHandoffParksWithoutInvokingSendOrCompletion() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let audit = Audit()
        let result = try await ProcessingPipeline().finishDeliveryHandoff(batch(root), stopBeforeIntegrations: true,
            run: { _ in Issue.record("Held export must not send"); return batch(root) },
            park: { await audit.add("park") }, checkpoint: { Issue.record("Held export cannot complete integrations") })
        #expect(result.held && result.completion == nil)
        #expect(await audit.events == ["park"])
    }

    @Test func completionRequiresAllDeliveriesAndAcknowledgedCheckpoint() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var saved = batch(root)
        saved.processingSucceededBeforeDeliveryAt = Date(timeIntervalSince1970: 10)
        let input = saved
        let audit = Audit()
        let result = try await ProcessingPipeline().finishDeliveryHandoff(input, stopBeforeIntegrations: false,
            run: { value in
                await audit.add("send")
                var value = value
                value.deliveries[0].status = .succeeded
                value.deliveries[0].updatedAt = Date(timeIntervalSince1970: 20)
                return value
            }, park: { Issue.record("Normal send cannot park") }, checkpoint: { await audit.add("checkpoint") })
        #expect(result.completion?.completedAt == Date(timeIntervalSince1970: 20))
        #expect(await audit.events == ["send", "checkpoint"])
        await #expect(throws: CocoaError.self) {
            _ = try await ProcessingPipeline().finishDeliveryHandoff(result.batch, stopBeforeIntegrations: false,
                run: { $0 }, park: {}, checkpoint: { throw CocoaError(.fileWriteOutOfSpace) })
        }
        let incomplete = try await ProcessingPipeline().finishDeliveryHandoff(input, stopBeforeIntegrations: false,
            run: { $0 }, park: {}, checkpoint: { Issue.record("Incomplete deliveries cannot checkpoint completion") })
        #expect(incomplete.completion == nil && !incomplete.batch.isComplete)
    }

    @Test func cancellationAfterSendKeepsConfirmedJournalButDoesNotAdvanceWorkflow() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = IntegrationDeliveryStore(rootURL: root)
        let saved = batch(root)
        try await store.save(saved)
        let coordinator = IntegrationDeliveryCoordinator(store: store)
        let pipeline = ProcessingPipeline()
        let task = Task {
            try await pipeline.runDeliveries(.init(id: saved.id, configurationDigests: [.webhook: "fixture"]),
                coordinator: coordinator, send: { _, entry in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .init(destination: entry.destination, status: .success, message: "Synthetic success", remoteID: "remote-id")
                })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let stored = try #require(try await store.load(id: saved.id))
        #expect(stored.deliveries[0].status == .succeeded && stored.deliveries[0].remoteID == "remote-id")
    }

    @Test func uncertainDeliveryRequiresExplicitRetryAndKeepsItsIdentifier() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = IntegrationDeliveryStore(rootURL: root)
        var saved = batch(root)
        saved.deliveries[0].status = .uncertain
        try await store.save(saved)
        let coordinator = IntegrationDeliveryCoordinator(store: store)
        let pipeline = ProcessingPipeline()
        let held = try await pipeline.runDeliveries(.init(id: saved.id, configurationDigests: [.webhook: "fixture"]),
            coordinator: coordinator, send: { _, entry in
                Issue.record("Unconfirmed retry cannot send")
                return .init(destination: entry.destination, status: .failed, message: "Unexpected", remoteID: nil)
            })
        #expect(held.deliveries[0].status == .uncertain)
        let expectedID = saved.deliveries[0].id
        let sent = try await pipeline.runDeliveries(.init(id: saved.id, configurationDigests: [.webhook: "fixture"], allowUncertainRetry: true),
            coordinator: coordinator, send: { _, entry in
                #expect(entry.id == expectedID)
                return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: nil)
            })
        #expect(sent.isComplete)
    }
    @Test @MainActor func preparationReusesFrozenIntentWithoutReadingChangedInputs() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        var saved = batch(root)
        saved.processingSucceededBeforeDeliveryAt = Date(timeIntervalSince1970: 10)
        try await store.save(saved)
        let recording = Recording(fileURL: saved.bundle.audioFileURL, finalizedAudioURL: saved.bundle.audioFileURL)
        try Data("corrupt transcript".utf8).write(to: root.appendingPathComponent("audio.transcript.json"))
        let request = ProcessingPipeline.DeliveryPreparation(jobID: saved.id,
            recording: RecordingSnapshot(recording: recording), configuration: IntegrationSettings(),
            markdownURL: root.appendingPathComponent("missing-note.md"), requireTranscript: true,
            processingSucceededBeforeDeliveryAt: nil)
        let result = try await ProcessingPipeline().prepareDeliveries(request, store: store, service: IntegrationDispatchService())
        #expect(result == saved, "Changed settings/content cannot replace frozen delivery identity or success provenance")
    }

    @Test @MainActor func newPreparationPersistsIntentAndRetainsUnknownCompletionProvenance() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
        let recording = Recording(fileURL: root.appendingPathComponent("audio.wav"))
        recording.transcription = .init(text: "Synthetic transcript", segments: [])
        var config = IntegrationSettings()
        config.webhook.enabled = true
        config.webhook.url = "https://synthetic.invalid"
        let request = ProcessingPipeline.DeliveryPreparation(jobID: UUID(), recording: RecordingSnapshot(recording: recording),
            configuration: config, markdownURL: nil, requireTranscript: true, processingSucceededBeforeDeliveryAt: nil)
        let result = try await ProcessingPipeline().prepareDeliveries(request, store: store, service: IntegrationDispatchService())
        #expect(try await store.load(id: request.jobID) == result)
        #expect(result.processingSucceededBeforeDeliveryAt == nil && result.successfulWorkflowCompletion == nil)
        #expect(result.bundle.transcript == "Synthetic transcript" && result.deliveries.count == 1)
    }

    @Test func ownershipLostAtStartedEventNeverCallsSenderAndKeepsInFlightEvidence() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = IntegrationDeliveryStore(rootURL: root)
        let saved = batch(root)
        try await store.save(saved)
        let audit = Audit()
        await #expect(throws: CancellationError.self) {
            _ = try await ProcessingPipeline().runDeliveries(.init(id: saved.id, configurationDigests: [.webhook: "fixture"]),
                coordinator: IntegrationDeliveryCoordinator(store: store), send: { _, entry in
                    Issue.record("A replaced job cannot send content")
                    return .init(destination: entry.destination, status: .failed, message: "Unexpected", remoteID: nil)
                }, onEvent: { event in
                    if case .started = event {
                        let current = try? await store.load(id: saved.id)
                        #expect(current?.deliveries.first?.status == .inFlight)
                        await audit.relinquish()
                    }
                }, validateOwnership: {
                    guard await audit.owns else { throw CancellationError() }
                })
        }
        let result = try #require(try await store.load(id: saved.id))
        #expect(result.deliveries[0].status == .uncertain && result.deliveries[0].attempts == 1)
    }

    @Test(arguments: [true, false])
    func cancellationAtBoundaryDoesNotReturnCompletion(hold: Bool) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var saved = batch(root)
        saved.deliveries = []
        saved.processingSucceededBeforeDeliveryAt = .now
        let input = saved
        let task = Task {
            try await ProcessingPipeline().finishDeliveryHandoff(input, stopBeforeIntegrations: hold,
                run: { $0 }, park: { withUnsafeCurrentTask { $0?.cancel() } },
                checkpoint: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test @MainActor func deliveryEventsAndSendKeepTheOriginatingPrivacyScope() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = IntegrationDeliveryStore(rootURL: root)
        let saved = batch(root)
        try await store.save(saved)
        let context = PrivacyTrace.Context(receiptURL: root.appendingPathComponent("privacy.json"), recordingID: saved.recordingID)
        let result = try await PrivacyTrace.$context.withValue(context) {
            try await ProcessingPipeline().runDeliveries(.init(id: saved.id, configurationDigests: [.webhook: "fixture"]),
                coordinator: IntegrationDeliveryCoordinator(store: store), send: { _, entry in
                    #expect(PrivacyTrace.context?.runID == context.runID)
                    return .init(destination: entry.destination, status: .success, message: "Synthetic success", remoteID: nil)
                }, onEvent: { @MainActor _ in
                    MainActor.preconditionIsolated()
                    #expect(PrivacyTrace.context?.recordingID == context.recordingID)
                })
        }
        #expect(result.isComplete)
    }

}
