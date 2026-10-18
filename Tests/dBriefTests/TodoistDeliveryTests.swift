import Foundation
import Testing
@testable import dBrief

@Suite("Todoist delivery")
struct TodoistDeliveryTests {
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

    private func harness(tokenStored: Bool = true,
                         respond: @escaping @Sendable (TickTickStubProtocol.Seen) -> TickTickStubProtocol.Reply) throws -> Harness {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("todoist-delivery-\(UUID())")
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
            todoistToken: { tokenStored ? token : "" })
        var config = IntegrationSettings()
        config.todoist = TodoistConfig(enabled: true, projectID: "p1", projectName: "Work")
        return Harness(folder: folder, token: token, session: session, service: service, log: log, config: config)
    }

    private func batch(_ h: Harness, items: [String], created: [Int: String]? = nil)
        throws -> (IntegrationDeliveryBatch, IntegrationDeliveryBatch.Delivery) {
        let audio = h.folder.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: audio)
        let bundle = IntegrationContentBundle(title: "Weekly sync", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: 60, audioFileURL: audio, transcript: nil, summary: nil, actionItems: items,
            tags: [], sentiment: nil, markdown: nil, calendarEvent: nil)
        let digest = try #require(try IntegrationDeliveryBatch.configurationDigests(h.config)[.todoist])
        var delivery = IntegrationDeliveryBatch.Delivery(id: UUID(), destination: .todoist, configurationDigest: digest)
        delivery.attempts = created == nil ? 1 : 2
        delivery.createdItems = created
        return (IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(), bundle: bundle,
                                         deliveries: [delivery]), delivery)
    }

    /// The item_add commands in a stubbed /sync request body.
    private static func commands(_ seen: TickTickStubProtocol.Seen) -> [[String: Any]] {
        guard let json = URLComponents(string: "?" + seen.body)?.queryItems?.first(where: { $0.name == "commands" })?.value,
              let array = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return array
    }

    /// Answers every command "ok" and maps each temp_id to "id-<content>".
    private static func acceptAll(_ seen: TickTickStubProtocol.Seen) -> TickTickStubProtocol.Reply {
        var status: [String: Any] = [:], mapping: [String: Any] = [:]
        for command in commands(seen) {
            status[command["uuid"] as! String] = "ok"
            let content = (command["args"] as? [String: Any])?["content"] as? String ?? ""
            mapping[command["temp_id"] as! String] = "id-\(content)"
        }
        let body = try! JSONSerialization.data(withJSONObject: ["sync_status": status, "temp_id_mapping": mapping])
        return .status(200, String(decoding: body, as: UTF8.self))
    }

    @Test func sendsAllItemsInOneSyncWithStableCommandIDs() async throws {
        let h = try harness(respond: Self.acceptAll)
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["Send deck", "  ", " Book room "])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.createdItems == [0: "id-Send deck", 2: "id-Book room"])
        #expect(h.log.posts.count == 1)
        let sent = Self.commands(try #require(h.log.posts.first))
        #expect(sent.map { $0["uuid"] as? String } == [TodoistAPI.commandUUID(deliveryID: delivery.id, digest: delivery.configurationDigest, index: 0),
                                                        TodoistAPI.commandUUID(deliveryID: delivery.id, digest: delivery.configurationDigest, index: 2)])
        let args = try #require(sent.first?["args"] as? [String: String])
        #expect(args["project_id"] == "p1")
        #expect(args["description"]?.hasPrefix("From “Weekly sync”") == true)
    }

    @Test func partialFailureKeepsCreatedItemsAndRetryResendsOnlyTheRest() async throws {
        let h = try harness { seen in
            var status: [String: Any] = [:], mapping: [String: Any] = [:]
            for command in Self.commands(seen) {
                let content = (command["args"] as? [String: Any])?["content"] as? String ?? ""
                if content == "B" {
                    status[command["uuid"] as! String] = ["error_code": 20, "error": "Invalid argument value"]
                } else {
                    status[command["uuid"] as! String] = "ok"
                    mapping[command["temp_id"] as! String] = "id-\(content)"
                }
            }
            let body = try! JSONSerialization.data(withJSONObject: ["sync_status": status, "temp_id_mapping": mapping])
            return .status(200, String(decoding: body, as: UTF8.self))
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A", "B"])
        let first = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(first.status == .failed)
        #expect(first.createdItems == [0: "id-A"])
        #expect(first.message.contains("Invalid argument value"))

        var retry = delivery
        retry.attempts = 2
        retry.createdItems = first.createdItems
        _ = await h.service.send(batch: batch, delivery: retry, config: h.config)
        let resent = Self.commands(h.log.posts[1])
        #expect(resent.map { $0["uuid"] as? String } == [TodoistAPI.commandUUID(deliveryID: delivery.id, digest: delivery.configurationDigest, index: 1)])
    }

    @Test func moreThanOneHundredItemsAreSplit() async throws {
        let h = try harness(respond: Self.acceptAll)
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: (0..<150).map { "Item \($0)" })
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.createdItems?.count == 150)
        #expect(h.log.posts.map { Self.commands($0).count } == [100, 50])
    }

    @Test func whitespaceOnlyItemsAreSkipped() async throws {
        let h = try harness(respond: Self.acceptAll)
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: [" ", ""])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .skipped)
        #expect(h.log.all.isEmpty)
    }

    @Test func rejectedTokenSaysSo() async throws {
        let h = try harness { _ in .status(401, #"{"error_tag":"UNAUTHORIZED"}"#) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A"])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(result.message == TodoistError.unauthorized.localizedDescription)
    }

    @Test func changedProjectBlocksTheSend() async throws {
        var h = try harness(respond: Self.acceptAll)
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A"])
        h.config.todoist.projectID = "another"
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(h.log.all.isEmpty)
    }

    @Test @MainActor func noTokenLeavesTodoistOutOfTheBatch() async throws {
        for stored in [false, true] {
            let h = try harness(tokenStored: stored, respond: Self.acceptAll)
            defer { h.cleanUp() }
            let recording = Recording(fileURL: h.folder.appendingPathComponent("meeting.m4a"))
            recording.actionItems = ["A"]
            let prepared = try await h.service.prepareBatch(jobID: UUID(), recording: RecordingSnapshot(recording: recording),
                                                            config: h.config, generatedMarkdownURL: nil)
            #expect(prepared.deliveries.map(\.destination).contains(.todoist) == stored)
        }
    }

    @Test func listProjectsFollowsCursorsAndDropsInboxAndArchived() async throws {
        let key = UUID().uuidString
        let pages = TickTickSeenLog()
        TickTickStubProtocol.register(key: key) { seen in
            pages.append(seen)
            return pages.all.count == 1
                ? .status(200, #"{"results":[{"id":"in","name":"Inbox","inbox_project":true},{"id":"w","name":"Work"}],"next_cursor":"c2"}"#)
                : .status(200, #"{"results":[{"id":"o","name":"old","is_archived":true},{"id":"a","name":"errands"}],"next_cursor":null}"#)
        }
        let session = TickTickStubProtocol.session()
        defer {
            TickTickStubProtocol.unregister(key: key)
            session.invalidateAndCancel()
        }
        let projects = try await TodoistClient(session: session).listProjects(token: key)
        #expect(projects.map(\.id) == ["a", "w"])
        #expect(pages.all.count == 2)
    }
}

extension TodoistDeliveryTests {
    @Test func aPlaceholderIsNotSentAsATask() async throws {
        let h = try harness(respond: Self.acceptAll)
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["- No action items identified"])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .skipped)
        #expect(h.log.all.isEmpty)
    }
}
