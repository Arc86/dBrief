import Foundation
import Testing
@testable import dBrief

@Suite("TickTick client")
struct TickTickClientTests {
    private func withStub<T>(key: String = UUID().uuidString,
                             _ responder: @escaping TickTickStubProtocol.Responder,
                             _ body: (TickTickClient, String) async throws -> T) async rethrows -> T {
        TickTickStubProtocol.register(key: key, responder)
        let session = TickTickStubProtocol.session()
        defer {
            TickTickStubProtocol.unregister(key: key)
            session.invalidateAndCancel()
        }
        return try await body(TickTickClient(session: session), key)
    }

    @Test func listProjectsDropsClosedListsAndSortsByName() async throws {
        let projects = try await withStub({ seen in
            #expect(seen.method == "GET")
            #expect(seen.path == "/open/v1/project")
            return .status(200, #"[{"id":"b","name":"Work"},{"id":"c","name":"Old","closed":true},{"id":"a","name":"errands"}]"#)
        }) { client, token in try await client.listProjects(token: token) }
        #expect(projects.map(\.id) == ["a", "b"])
    }

    @Test func unauthorizedAndServerErrorsAreTyped() async {
        await #expect(throws: TickTickError.unauthorized) {
            try await withStub({ _ in .status(401, "") }) { client, token in try await client.listProjects(token: token) }
        }
        await #expect(throws: TickTickError.http(503)) {
            try await withStub({ _ in .status(503, "busy") }) { client, token in try await client.listProjects(token: token) }
        }
        await #expect(throws: TickTickError.invalidResponse) {
            try await withStub({ _ in .status(200, "not json") }) { client, token in try await client.listProjects(token: token) }
        }
    }

    @Test func createTaskSendsJSONAndReturnsTheID() async throws {
        let log = TickTickSeenLog()
        let id = try await withStub({ seen in
            log.append(seen)
            return .status(200, #"{"id":"t1","projectId":"p1","title":"Send deck"}"#)
        }) { client, token in
            try await client.createTask(title: "Send deck", content: "From x", projectID: "p1", token: token)
        }
        #expect(id == "t1")
        let post = try #require(log.posts.first)
        #expect(post.path == "/open/v1/task")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: String])
        #expect(json == ["title": "Send deck", "content": "From x", "projectId": "p1"])
    }

    @Test func createTaskAcceptsCreatedWithoutBody() async throws {
        let id = try await withStub({ _ in .status(201, "") }) { client, token in
            try await client.createTask(title: "A", content: "B", projectID: "inbox", token: token)
        }
        #expect(id == "")
    }

    @Test func projectTasksReadsTheTaskList() async throws {
        let tasks = try await withStub({ seen in
            #expect(seen.path == "/open/v1/project/inbox/data")
            return .status(200, #"{"project":{"id":"inbox"},"tasks":[{"id":"t1","title":"A","content":"From x"},{"id":"t2"}]}"#)
        }) { client, token in try await client.projectTasks(projectID: "inbox", token: token) }
        #expect(tasks == [TickTickTask(id: "t1", title: "A", content: "From x"), TickTickTask(id: "t2")])
    }

    @Test func exchangeCodeReturnsTheAccessToken() async throws {
        let credentials = TickTickCredentials(clientID: UUID().uuidString, clientSecret: "secret")
        let basic = Data("\(credentials.clientID):secret".utf8).base64EncodedString()
        let token = try await withStub(key: basic, { seen in
            #expect(seen.path == "/oauth/token")
            #expect(seen.body.contains("code=abc"))
            return .status(200, #"{"access_token":"tok-1"}"#)
        }) { client, _ in try await client.exchangeCode("abc", credentials: credentials) }
        #expect(token == "tok-1")
    }
}
