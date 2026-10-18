import Foundation

struct TodoistProject: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    var isArchived: Bool? = nil
    var inboxProject: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name
        case isArchived = "is_archived"
        case inboxProject = "inbox_project"
    }
}

/// HTTP calls to Todoist. The /sync call carries meeting text, so it is
/// recorded in the recording's privacy receipt; project reads are not.
struct TodoistClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// Open projects sorted by name, without the Inbox (Settings lists it first).
    func listProjects(token: String) async throws -> [TodoistProject] {
        struct Page: Decodable {
            let results: [TodoistProject]
            let nextCursor: String?
            enum CodingKeys: String, CodingKey { case results, nextCursor = "next_cursor" }
        }
        var projects: [TodoistProject] = []
        var cursor: String?
        for _ in 0..<20 {
            let data = try await send(TodoistAPI.projectsRequest(token: token, cursor: cursor))
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw TodoistError.invalidResponse }
            projects += page.results
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return projects.filter { $0.isArchived != true && $0.inboxProject != true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func sync(commands: [[String: Any]], token: String) async throws -> TodoistSyncResult {
        let operation = PrivacyOperation(stage: .integration, data: [.text, .metadata],
                                         destination: .remote(url: TodoistAPI.apiBase, provider: .todoist))
        let data = try await send(TodoistAPI.syncRequest(commands: commands, token: token), operation: operation)
        return try TodoistAPI.parseSync(data)
    }

    private func send(_ request: URLRequest, operation: PrivacyOperation? = nil) async throws -> Data {
        let (data, response): (Data, URLResponse)
        if let operation {
            (data, response) = try await PrivacyHTTPTrace.data(for: request, operation: operation, session: session)
        } else {
            (data, response) = try await PrivacyHTTPTrace.untracedData(for: request, session: session)
        }
        guard let http = response as? HTTPURLResponse else { throw TodoistError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw TodoistError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw TodoistError.http(http.statusCode) }
        return data
    }
}
