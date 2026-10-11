import Foundation
import Testing
@testable import dBrief

@Suite("Todoist API requests")
struct TodoistAPITests {
    @Test func commandUUIDIsStablePerDeliveryAndItem() throws {
        let delivery = try #require(UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000000"))
        let first = TodoistAPI.commandUUID(deliveryID: delivery, digest: "d", index: 0)
        #expect(first == TodoistAPI.commandUUID(deliveryID: delivery, digest: "d", index: 0))
        #expect(first != TodoistAPI.commandUUID(deliveryID: delivery, digest: "d", index: 1))
        #expect(first != TodoistAPI.commandUUID(deliveryID: UUID(), digest: "d", index: 0))
        // Sending again with accepted new settings must not be ignored as a repeat.
        #expect(first != TodoistAPI.commandUUID(deliveryID: delivery, digest: "other", index: 0))
        #expect(UUID(uuidString: first) != nil)
        #expect(first == first.lowercased())
    }

    @Test func itemAddCommandOmitsProjectForInbox() throws {
        let inbox = TodoistAPI.itemAdd(uuid: "u1", tempID: "t1", content: "Send deck", description: "From x", projectID: nil)
        #expect(inbox["type"] as? String == "item_add")
        #expect(inbox["uuid"] as? String == "u1")
        #expect(inbox["temp_id"] as? String == "t1")
        let args = try #require(inbox["args"] as? [String: String])
        #expect(args == ["content": "Send deck", "description": "From x"])
        let project = TodoistAPI.itemAdd(uuid: "u1", tempID: "t1", content: "A", description: "B", projectID: "p1")
        #expect((project["args"] as? [String: String])?["project_id"] == "p1")
    }

    @Test func syncRequestIsFormEncodedCommandsWithBearer() throws {
        let command = TodoistAPI.itemAdd(uuid: "u1", tempID: "t1", content: "Café & co", description: "d", projectID: nil)
        let request = try TodoistAPI.syncRequest(commands: [command], token: "tok")
        #expect(request.url?.absoluteString == "https://api.todoist.com/api/v1/sync")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        let decoded = try #require(URLComponents(string: "?" + body)?.queryItems?.first { $0.name == "commands" }?.value)
        let array = try #require(try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [[String: Any]])
        #expect((array.first?["args"] as? [String: String])?["content"] == "Café & co")
    }

    @Test func projectsRequestPagesWithCursor() {
        #expect(TodoistAPI.projectsRequest(token: "tok", cursor: nil).url?.absoluteString
            == "https://api.todoist.com/api/v1/projects?limit=200")
        #expect(TodoistAPI.projectsRequest(token: "tok", cursor: "c 1").url?.absoluteString
            == "https://api.todoist.com/api/v1/projects?limit=200&cursor=c%201")
    }

    @Test func syncResponseSeparatesSuccessesErrorsAndIDs() throws {
        let data = Data(#"""
        {"sync_status":{"u1":"ok","u2":{"error_tag":"INVALID_ARGUMENT_VALUE","error_code":20,"error":"Invalid argument value"}},
         "temp_id_mapping":{"t1":"real-1"}}
        """#.utf8)
        let result = try TodoistAPI.parseSync(data)
        #expect(result.succeeded == ["u1"])
        #expect(result.errors == ["u2": "Invalid argument value"])
        #expect(result.tempIDMapping == ["t1": "real-1"])
        #expect(throws: TodoistError.invalidResponse) { try TodoistAPI.parseSync(Data("nope".utf8)) }
    }

    @Test func taskDescriptionNamesTheMeeting() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let zone = try #require(TimeZone(identifier: "UTC"))
        #expect(TodoistAPI.taskDescription(meetingTitle: " Weekly sync ", date: date, locale: Locale(identifier: "en_US"), timeZone: zone)
            == "From “Weekly sync” · Sep 21, 2026 — added by dBrief")
    }
}
