import Foundation
import Testing
@testable import dBrief

@Suite("Notion delivery")
struct NotionDeliveryTests {
    typealias Seen = TickTickStubProtocol.Seen
    typealias Reply = TickTickStubProtocol.Reply

    private struct Harness {
        let folder: URL
        let token: String
        let session: URLSession
        let service: IntegrationDispatchService
        let log: TickTickSeenLog
        var config: IntegrationSettings

        func cleanUp() {
            TickTickStubProtocol.unregister(key: token)
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func harness(parent: NotionParentType = .page, parentID: String = "parent-1", tokenStored: Bool = true,
                         respond: @escaping @Sendable (Seen) -> Reply) throws -> Harness {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notion-delivery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let log = TickTickSeenLog()
        TickTickStubProtocol.register(key: token) { seen in
            log.append(seen)
            return respond(seen)
        }
        let session = TickTickStubProtocol.session()
        let service = IntegrationDispatchService(
            session: session, privacyStore: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")),
            privacyPendingRoot: folder.appendingPathComponent("pending"),
            notionToken: { tokenStored ? token : "" })
        var config = IntegrationSettings()
        config.notion.enabled = true
        config.notion.parentType = parent
        config.notion.parentID = parentID
        config.notion.parentName = "Team notes"
        config.notion.fields = [.summary, .actionItems, .transcript]
        return Harness(folder: folder, token: token, session: session, service: service, log: log, config: config)
    }

    private func batch(_ h: Harness, transcriptLines: Int = 3, attempts: Int = 1, created: [Int: String]? = nil)
        throws -> (IntegrationDeliveryBatch, IntegrationDeliveryBatch.Delivery) {
        let audio = h.folder.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: audio)
        // 1,500-char lines so each becomes its own paragraph block.
        let transcript = (0..<transcriptLines).map { "Line \($0) " + String(repeating: "x", count: 1_500) }
            .joined(separator: "\n")
        let bundle = IntegrationContentBundle(title: "Weekly sync", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: 600, audioFileURL: audio, transcript: transcript, summary: "Short summary.",
            actionItems: ["Send deck"], tags: ["q3"], sentiment: nil, markdown: nil, calendarEvent: nil)
        let digest = try #require(try IntegrationDeliveryBatch.configurationDigests(h.config)[.notion])
        var delivery = IntegrationDeliveryBatch.Delivery(id: UUID(), destination: .notion, configurationDigest: digest)
        delivery.attempts = attempts
        delivery.createdItems = created
        return (IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(), bundle: bundle,
                                         deliveries: [delivery]), delivery)
    }

    private func blockCount(_ h: Harness, _ batch: IntegrationDeliveryBatch) -> Int {
        NotionAPI.blocks(for: batch.bundle, fields: h.config.notion.fields, reference: NotionAPI.reference(for: batch.id)).count
    }

    private static func json(_ seen: Seen) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(seen.body.utf8))) as? [String: Any] ?? [:]
    }

    private static func children(_ seen: Seen) -> Int { (json(seen)["children"] as? [Any])?.count ?? 0 }

    private static func ok(_ object: [String: Any]) -> Reply {
        .status(200, String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    @Test func createsThePageThenAppendsTheRestInBatches() async throws {
        let h = try harness { seen in
            seen.path == "/v1/pages" ? Self.ok(["id": "pg"]) : Self.ok(["results": []])
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, transcriptLines: 230)
        let total = blockCount(h, batch)
        #expect(total > 200)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.remoteID == "pg")
        #expect(result.createdItems == [0: "pg", 1: "\(total)"])
        let writes = h.log.all.filter { $0.method != "GET" }
        #expect(writes.map(\.path) == ["/v1/pages", "/v1/blocks/pg/children", "/v1/blocks/pg/children"])
        #expect(writes.map(Self.children) == [100, 100, total - 200])
        let page = Self.json(writes[0])
        #expect((page["parent"] as? [String: String]) == ["type": "page_id", "page_id": "parent-1"])
        #expect((page["properties"] as? [String: Any])?["title"] != nil)
    }

    @Test func databaseEntriesFillTheirColumns() async throws {
        let h = try harness(parent: .dataSource, parentID: "ds-1") { seen in
            switch (seen.method, seen.path) {
            case ("GET", "/v1/data_sources/ds-1"):
                return Self.ok(["properties": ["Name": ["type": "title"], "Date": ["type": "date"],
                                               "Tags": ["type": "multi_select"]]])
            default:
                return Self.ok(["id": "pg"])
            }
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        let page = Self.json(try #require(h.log.posts.first))
        #expect((page["parent"] as? [String: String]) == ["type": "data_source_id", "data_source_id": "ds-1"])
        let properties = try #require(page["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["Name", "Date", "Tags"])
    }

    @Test func retryResumesFromTheRecordedPageAndCount() async throws {
        let h = try harness { _ in Self.ok(["results": []]) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, transcriptLines: 120, attempts: 2, created: [0: "pg", 1: "100"])
        let total = blockCount(h, batch)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.createdItems == [0: "pg", 1: "\(total)"])
        #expect(h.log.all.map(\.path) == ["/v1/blocks/pg/children"])
        #expect(Self.children(h.log.all[0]) == total - 100)
    }

    @Test func lostResponseRetryAdoptsThePageCarryingThisMeetingsReference() async throws {
        let id = UUID()
        let marker = "Sep 21, 2026 · 10 min — added by dBrief (ref \(NotionAPI.reference(for: id)))"
        let h = try harness { seen in
            switch (seen.method, seen.path) {
            case ("POST", "/v1/search"):
                return Self.ok(["results": [
                    ["object": "page", "id": "other", "parent": ["type": "page_id", "page_id": "elsewhere"]],
                    ["object": "page", "id": "p1", "parent": ["type": "page_id", "page_id": "parent-1"]],
                ], "has_more": false])
            case ("GET", "/v1/blocks/p1/children"):
                let first: [String: Any] = ["type": "paragraph", "paragraph": ["rich_text": [["plain_text": marker]]]]
                return Self.ok(["results": [first, ["type": "heading_2"], ["type": "paragraph"]], "has_more": false])
            default:
                return Self.ok(["id": "new"])
            }
        }
        defer { h.cleanUp() }
        var (batch, delivery) = try batch(h, attempts: 2)
        batch = IntegrationDeliveryBatch(id: id, recordingID: batch.recordingID, createdAt: batch.createdAt,
                                         bundle: batch.bundle, deliveries: batch.deliveries)
        let total = blockCount(h, batch)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.createdItems == [0: "p1", 1: "\(total)"])
        #expect(!h.log.all.contains { $0.path == "/v1/pages" })
        let append = try #require(h.log.all.first { $0.method == "PATCH" })
        #expect(Self.children(append) == total - 3)
    }

    @Test func aSameTitledPageWithoutTheReferenceIsNotReused() async throws {
        let h = try harness { seen in
            switch (seen.method, seen.path) {
            case ("POST", "/v1/search"):
                return Self.ok(["results": [["object": "page", "id": "p1", "parent": ["type": "page_id", "page_id": "parent-1"]]]])
            case ("GET", "/v1/blocks/p1/children"):
                return Self.ok(["results": [["type": "paragraph", "paragraph": ["rich_text": [["plain_text": "added by dBrief (ref 00000000)"]]]]]])
            default:
                return Self.ok(["id": "new"])
            }
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, attempts: 2)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.createdItems?[0] == "new")
        #expect(h.log.posts.contains { $0.path == "/v1/pages" })
    }

    @Test func failureMidWriteKeepsProgress() async throws {
        let h = try harness { seen in
            seen.path == "/v1/pages" ? Self.ok(["id": "pg"]) : .status(500, "")
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, transcriptLines: 150)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(result.createdItems == [0: "pg", 1: "100"])
    }

    @Test(arguments: [(401, NotionError.unauthorized), (404, NotionError.notShared), (429, NotionError.rateLimited)])
    func errorsExplainWhatToDo(status: Int, error: NotionError) async throws {
        let h = try harness { _ in .status(status, "{}") }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(result.message == error.localizedDescription)
    }

    @Test func changedDestinationBlocksTheSend() async throws {
        var h = try harness { _ in Self.ok(["id": "pg"]) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h)
        h.config.notion.parentID = "another"
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(h.log.all.isEmpty)
    }

    @Test @MainActor func missingSecretOrDestinationLeavesNotionOutOfTheBatch() async throws {
        for (stored, parentID, expected) in [(false, "parent-1", false), (true, "", false), (true, "parent-1", true)] {
            let h = try harness(parentID: parentID, tokenStored: stored) { _ in Self.ok([:]) }
            defer { h.cleanUp() }
            let recording = Recording(fileURL: h.folder.appendingPathComponent("meeting.m4a"))
            recording.summary = "S"
            let prepared = try await h.service.prepareBatch(jobID: UUID(), recording: RecordingSnapshot(recording: recording),
                                                            config: h.config, generatedMarkdownURL: nil)
            #expect(prepared.deliveries.map(\.destination).contains(.notion) == expected)
        }
    }

    @Test func searchListsPagesAndDatabasesAcrossPages() async throws {
        let key = UUID().uuidString
        let calls = TickTickSeenLog()
        TickTickStubProtocol.register(key: key) { seen in
            calls.append(seen)
            return calls.all.count == 1
                ? Self.ok(["results": [["object": "page", "id": "p1", "properties": ["title": ["type": "title", "title": [["plain_text": "Team"]]]]]],
                           "has_more": true, "next_cursor": "c2"])
                : Self.ok(["results": [["object": "data_source", "id": "d1", "title": [["plain_text": "Meetings"]]]], "has_more": false])
        }
        let session = TickTickStubProtocol.session()
        defer { TickTickStubProtocol.unregister(key: key); session.invalidateAndCancel() }
        let destinations = try await NotionClient(session: session).search(token: key)
        #expect(destinations == [NotionDestination(kind: .page, id: "p1", name: "Team"),
                                 NotionDestination(kind: .dataSource, id: "d1", name: "Meetings")])
        #expect((Self.json(calls.all[1])["start_cursor"] as? String) == "c2")
    }
}
