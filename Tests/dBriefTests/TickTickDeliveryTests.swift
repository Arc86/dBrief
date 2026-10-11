import Foundation
import Testing
@testable import dBrief

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("TickTick delivery")
struct TickTickDeliveryTests {
    private let offered = IntegrationDestination.available(tickTickConfigured: true)

    private struct Harness {
        let folder: URL
        let token: String
        let session: URLSession
        let service: IntegrationDispatchService
        let expired: Counter
        let log: TickTickSeenLog
        var config: IntegrationSettings

        func cleanUp() {
            TickTickStubProtocol.unregister(key: token)
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func harness(tokenStored: Bool = true,
                         respond: @escaping @Sendable (TickTickStubProtocol.Seen, Int) -> TickTickStubProtocol.Reply)
        throws -> Harness {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ticktick-delivery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let log = TickTickSeenLog()
        let posts = Counter()
        TickTickStubProtocol.register(key: token) { seen in
            log.append(seen)
            if seen.method == "POST" { posts.increment() }
            return respond(seen, posts.count)
        }
        let session = TickTickStubProtocol.session()
        let expired = Counter()
        let service = IntegrationDispatchService(
            session: session, privacyStore: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")),
            privacyPendingRoot: folder.appendingPathComponent("pending"), available: offered,
            tickTickToken: { tokenStored ? token : "" }, tickTickSessionExpired: { expired.increment() })
        var config = IntegrationSettings()
        config.tickTick = TickTickConfig(enabled: true, projectID: "p1", projectName: "Work")
        return Harness(folder: folder, token: token, session: session, service: service,
                       expired: expired, log: log, config: config)
    }

    private func batch(_ harness: Harness, items: [String], attempts: Int = 1,
                       created: [Int: String]? = nil) throws -> (IntegrationDeliveryBatch, IntegrationDeliveryBatch.Delivery) {
        let audio = harness.folder.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: audio)
        let bundle = IntegrationContentBundle(title: "Weekly sync", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: 60, audioFileURL: audio, transcript: nil, summary: nil, actionItems: items,
            tags: [], sentiment: nil, markdown: nil, calendarEvent: nil)
        let digest = try #require(try IntegrationDeliveryBatch.configurationDigests(harness.config, available: offered)[.tickTick])
        var delivery = IntegrationDeliveryBatch.Delivery(id: UUID(), destination: .tickTick, configurationDigest: digest)
        delivery.attempts = attempts
        delivery.createdItems = created
        let batch = IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(),
                                             bundle: bundle, deliveries: [delivery])
        return (batch, delivery)
    }

    private func content() -> String {
        TickTickAPI.taskContent(meetingTitle: "Weekly sync", date: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func titles(_ log: TickTickSeenLog) -> [String] {
        log.posts.compactMap { post in
            (try? JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: String])?["title"]
        }
    }

    @Test func sendsOneTaskPerNonEmptyItem() async throws {
        let h = try harness { seen, posts in .status(200, #"{"id":"t\#(posts)"}"#) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["Send deck", "  ", " Book room "])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.createdItems == [0: "t1", 2: "t2"])
        #expect(result.remoteID == "t1,t2")
        #expect(titles(h.log) == ["Send deck", "Book room"])
        let first = try #require(try JSONSerialization.jsonObject(with: Data(h.log.posts[0].body.utf8)) as? [String: String])
        #expect(first["projectId"] == "p1")
        #expect(first["content"] == content())
        #expect(!h.log.all.contains { $0.method == "GET" })
    }

    @Test func whitespaceOnlyItemsAreSkipped() async throws {
        let h = try harness { _, _ in .status(500, "") }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: [" ", ""])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .skipped)
        #expect(h.log.all.isEmpty)
    }

    @Test func retrySkipsRecordedItemsAndMatchesExistingTasks() async throws {
        let marker = content()
        let h = try harness { seen, _ in
            if seen.method == "GET" {
                #expect(seen.path == "/open/v1/project/p1/data")
                return .status(200, #"{"tasks":[{"id":"t-b","title":"B","content":"\#(marker)"},{"id":"x","title":"C","content":"other"}]}"#)
            }
            return .status(200, #"{"id":"t-c"}"#)
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A", "B", "C"], attempts: 2, created: [0: "t-a"])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.createdItems == [0: "t-a", 1: "t-b", 2: "t-c"])
        #expect(titles(h.log) == ["C"])
        #expect(h.log.all.filter { $0.method == "GET" }.count == 1)
    }

    @Test func duplicateTitlesClaimOneExistingTaskEach() async throws {
        let marker = content()
        let h = try harness { seen, _ in
            seen.method == "GET"
                ? .status(200, #"{"tasks":[{"id":"t1","title":"Follow up","content":"\#(marker)"}]}"#)
                : .status(200, #"{"id":"t2"}"#)
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["Follow up", "Follow up"], attempts: 2)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.createdItems == [0: "t1", 1: "t2"])
        #expect(titles(h.log) == ["Follow up"])
    }

    @Test func failureKeepsProgressForTheNextAttempt() async throws {
        let h = try harness { _, posts in posts == 1 ? .status(200, #"{"id":"t-a"}"#) : .failure(.networkConnectionLost) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A", "B"])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(result.createdItems == [0: "t-a"])
        #expect(h.expired.count == 0)
    }

    @Test func unauthorizedMarksTheSessionExpired() async throws {
        let h = try harness { _, _ in .status(401, "") }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A"])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(result.createdItems == nil)
        #expect(h.expired.count == 1)
    }

    @Test func changedListBlocksTheRetry() async throws {
        var h = try harness { _, _ in .status(200, #"{"id":"t1"}"#) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A"], attempts: 2)
        h.config.tickTick.projectID = "another-list"
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(h.log.all.isEmpty)
    }

    @Test @MainActor func notSignedInLeavesTickTickOutOfTheBatch() async throws {
        for stored in [false, true] {
            let h = try harness(tokenStored: stored) { _, _ in .status(500, "") }
            defer { h.cleanUp() }
            let recording = Recording(fileURL: h.folder.appendingPathComponent("meeting.m4a"))
            recording.actionItems = ["A"]
            let prepared = try await h.service.prepareBatch(jobID: UUID(), recording: RecordingSnapshot(recording: recording),
                                                            config: h.config, generatedMarkdownURL: nil)
            #expect(prepared.deliveries.map(\.destination).contains(.tickTick) == stored)
        }
    }
}
