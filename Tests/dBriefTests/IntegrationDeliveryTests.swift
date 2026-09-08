import Foundation
import Testing
import dBriefWire
@testable import dBrief

private actor DeliveryTestStore: IntegrationDeliveryPersistence {
    var batch: IntegrationDeliveryBatch
    var saves = 0
    let failOnSave: Int?
    init(_ batch: IntegrationDeliveryBatch, failOnSave: Int? = nil) {
        self.batch = batch
        self.failOnSave = failOnSave
    }
    func load(id: UUID) -> IntegrationDeliveryBatch? { batch.id == id ? batch : nil }
    func save(_ value: IntegrationDeliveryBatch) throws {
        saves += 1
        if saves == failOnSave { throw IntegrationDeliveryStore.StoreError.verificationFailed }
        batch = value
    }
}

private actor DeliveryCalls {
    var ids: [UUID] = []
    func append(_ id: UUID) { ids.append(id) }
}

@Suite("Durable integration delivery")
struct IntegrationDeliveryTests {
    private func batch() -> IntegrationDeliveryBatch {
        IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(),
            bundle: .init(title: "Meeting", createdAt: Date(), durationSeconds: 60,
                          audioFileURL: URL(fileURLWithPath: "/tmp/meeting.m4a"),
                          transcript: "Transcript", summary: "Summary", actionItems: ["Follow up"],
                          tags: [], sentiment: nil, markdown: "# Meeting", calendarEvent: nil),
            deliveries: [
                .init(id: UUID(), destination: .appleNotes, configurationDigest: "notes"),
                .init(id: UUID(), destination: .webhook, configurationDigest: "webhook")
            ])
    }
    private var digests: [IntegrationDestination: String] { [.appleNotes: "notes", .webhook: "webhook"] }

    @Test
    func successIsCheckpointedBeforeNextSendAndNeverRepeated() async throws {
        let original = batch()
        let store = DeliveryTestStore(original)
        let calls = DeliveryCalls()
        let coordinator = IntegrationDeliveryCoordinator(store: store)
        let first = try await coordinator.run(id: original.id, configurationDigests: digests) { saved, entry in
            let onDisk = await store.load(id: saved.id)
            #expect(onDisk?.deliveries.first(where: { $0.id == entry.id })?.status == .inFlight)
            await calls.append(entry.id)
            return .init(destination: entry.destination,
                         status: entry.destination == .appleNotes ? .success : .failed,
                         message: "Raw private response must not be persisted", remoteID: nil)
        }
        #expect(first.deliveries[0].status == .succeeded)
        #expect(first.deliveries[1].status == .uncertain)
        // A restart without explicit duplicate confirmation cannot resend either.
        _ = try await IntegrationDeliveryCoordinator(store: store).run(id: original.id, configurationDigests: digests) { _, entry in
            await calls.append(entry.id)
            return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: nil)
        }
        #expect(await calls.ids.count == 2)
        let retry = try await coordinator.run(id: original.id, configurationDigests: digests,
                                             destinations: [.webhook], allowUncertainRetry: true) { saved, entry in
            #expect(saved.bundle == original.bundle)
            #expect(entry.id == original.deliveries[1].id)
            await calls.append(entry.id)
            return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: "remote-id")
        }
        #expect(retry.isComplete)
        #expect(retry.deliveries[1].attempts == 2)
        #expect(await calls.ids == [original.deliveries[0].id, original.deliveries[1].id, original.deliveries[1].id])
        #expect(!String(decoding: try JSONEncoder().encode(retry), as: UTF8.self).contains("Raw private response"))
    }

    @Test
    func failureToSaveAttemptPreventsAnySend() async throws {
        let original = batch()
        let store = DeliveryTestStore(original, failOnSave: 1)
        let calls = DeliveryCalls()
        await #expect(throws: IntegrationDeliveryStore.StoreError.self) {
            _ = try await IntegrationDeliveryCoordinator(store: store).run(id: original.id, configurationDigests: digests) { _, entry in
                await calls.append(entry.id)
                return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: nil)
            }
        }
        #expect(await calls.ids.isEmpty)
    }

    @Test
    func lostResponseCheckpointStopsLaterSendsAndRequiresConfirmation() async throws {
        let original = batch()
        let store = DeliveryTestStore(original, failOnSave: 2)
        let calls = DeliveryCalls()
        await #expect(throws: IntegrationDeliveryStore.StoreError.self) {
            _ = try await IntegrationDeliveryCoordinator(store: store).run(id: original.id, configurationDigests: digests) { _, entry in
                await calls.append(entry.id)
                return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: "external")
            }
        }
        let saved = try #require(await store.load(id: original.id))
        #expect(saved.deliveries[0].needsDuplicateConfirmation)
        #expect(saved.deliveries[1].status == .pending)
        #expect(await calls.ids.count == 1)
    }

    @Test
    func cancellationKeepsConfirmedSuccessAndDoesNotSendNextDestination() async throws {
        let original = batch()
        let store = DeliveryTestStore(original)
        let coordinator = IntegrationDeliveryCoordinator(store: store)
        let task = Task {
            try await coordinator.run(id: original.id, configurationDigests: digests) { _, entry in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: "created")
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let saved = try #require(await store.load(id: original.id))
        #expect(saved.deliveries[0].status == .succeeded)
        #expect(saved.deliveries[0].remoteID == "created")
        #expect(saved.deliveries[1].status == .pending)
    }

    @Test
    func overlappingDispatchCannotSendTheSameBatchTwice() async throws {
        let original = batch()
        let store = DeliveryTestStore(original)
        let coordinator = IntegrationDeliveryCoordinator(store: store)
        _ = try await coordinator.run(id: original.id, configurationDigests: digests) { _, entry in
            await #expect(throws: IntegrationDeliveryStore.StoreError.self) {
                _ = try await coordinator.run(id: original.id, configurationDigests: digests) { _, unexpected in
                    Issue.record("Overlapping dispatch should never call send")
                    return .init(destination: unexpected.destination, status: .failed, message: "Unexpected", remoteID: nil)
                }
            }
            return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: nil)
        }
    }

    @Test
    func changedOrDisabledDestinationBlocksWithoutSending() async throws {
        let original = batch()
        let store = DeliveryTestStore(original)
        let calls = DeliveryCalls()
        let result = try await IntegrationDeliveryCoordinator(store: store).run(
            id: original.id, configurationDigests: [.webhook: "different-url"]
        ) { _, entry in
            await calls.append(entry.id)
            return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: nil)
        }
        #expect(result.deliveries.allSatisfy { $0.status == .blocked })
        #expect(await calls.ids.isEmpty)
    }

    @Test
    func selectedRetryLeavesOtherPendingDestinationsAlone() async throws {
        let original = batch()
        let store = DeliveryTestStore(original)
        let result = try await IntegrationDeliveryCoordinator(store: store).run(
            id: original.id, configurationDigests: digests, destinations: [.webhook]
        ) { _, entry in
            #expect(entry.destination == .webhook)
            return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: nil)
        }
        #expect(result.deliveries[0].status == .pending)
        #expect(result.deliveries[1].status == .succeeded)
    }

    @Test
    func explicitConfigurationApprovalUpdatesOnlyTheSelectedDestination() async throws {
        let original = batch()
        let store = DeliveryTestStore(original)
        let result = try await IntegrationDeliveryCoordinator(store: store).run(
            id: original.id, configurationDigests: [.webhook: "updated", .appleNotes: "also-changed"],
            destinations: [.webhook], acceptConfigurationChange: true
        ) { saved, entry in
            #expect(entry.configurationDigest == "updated")
            #expect(saved.bundle == original.bundle)
            return .init(destination: entry.destination, status: .success, message: "Sent", remoteID: nil)
        }
        #expect(result.deliveries[0].configurationDigest == "notes")
        #expect(result.deliveries[0].status == .pending)
        #expect(result.deliveries[1].status == .succeeded)
    }

    @Test
    func configurationFingerprintDoesNotPersistSecretsOrDependOnOtherDestinations() throws {
        var settings = IntegrationSettings()
        settings.webhook.enabled = true
        settings.webhook.url = "https://example.invalid/secret-path"
        settings.webhook.headers = [.init(key: "Authorization", value: "secret-token")]
        let first = try IntegrationDeliveryBatch.configurationDigests(settings)
        settings.webhook.headers = [.init(key: "Authorization", value: "rotated-token")]
        settings.webhook.timeoutSeconds = 120
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings)[.webhook] == first[.webhook])
        settings.appleNotes.enabled = true
        settings.appleNotes.folderName = "Different folder"
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings)[.webhook] == first[.webhook])
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!encoded.contains("secret-token"))
        #expect(!encoded.contains("secret-path"))
        settings.webhook.url = "https://example.invalid/other-account"
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings)[.webhook] != first[.webhook])
    }

    @Test
    func webhookKeyIsStableAndCannotBeOverriddenByCustomHeaders() {
        let id = UUID()
        var config = WebhookConfig()
        config.headers = [.init(key: "Idempotency-Key", value: "unstable")]
        let request = IntegrationDispatchService.webhookRequest(
            url: URL(string: "https://example.invalid")!, config: config,
            contentType: "application/json", deliveryID: id)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == id.uuidString.lowercased())
    }

    @Test @MainActor
    func deliverySnapshotRecoversTranscriptAfterMarkdownOnlyRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("recording.m4a")
        let sidecar = root.appendingPathComponent("recording.transcript.json")
        let transcript = TranscriptionResult(text: "Saved transcript", segments: [], language: "en")
        try JSONEncoder().encode(transcript).write(to: sidecar)
        let recording = Recording(fileURL: audio, finalizedAudioURL: audio)
        #expect(recording.transcription == nil)
        let snapshot = try RecordingSnapshot(recording: recording, recoverTranscript: true)
        #expect(snapshot.transcript == "Saved transcript")
        try Data("corrupt".utf8).write(to: sidecar)
        #expect(throws: (any Error).self) {
            _ = try RecordingSnapshot(recording: recording, recoverTranscript: true)
        }
    }

    @Test
    func storeRoundTripsAndRejectsFutureRecordsWithoutOverwritingThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IntegrationDeliveryStore(rootURL: root)
        var original = batch()
        try await store.save(original)
        #expect(try await store.load(id: original.id) == original)
        original.version = 99
        let url = root.appendingPathComponent(original.id.uuidString.lowercased()).appendingPathExtension("json")
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: url)
        await #expect(throws: IntegrationDeliveryStore.StoreError.self) {
            _ = try await store.load(id: original.id)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
