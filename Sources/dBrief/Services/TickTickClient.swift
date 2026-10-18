import Foundation

struct TickTickProject: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    var closed: Bool? = nil
}

struct TickTickTask: Decodable, Equatable, Sendable {
    let id: String
    var title: String? = nil
    var content: String? = nil
}

/// HTTP calls to TickTick. Creating a task carries meeting text, so it is
/// recorded in the recording's privacy receipt; sign-in and list reads are not.
struct TickTickClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func exchangeCode(_ code: String, credentials: TickTickCredentials) async throws -> String {
        try TickTickAPI.accessToken(from: await send(TickTickAPI.tokenRequest(code: code, credentials: credentials)))
    }

    /// Best effort: signing out removes the local token whatever this returns.
    func revoke(token: String, credentials: TickTickCredentials) async {
        var request = URLRequest(url: TickTickAPI.revokeEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = TickTickAPI.formBody([("token", token)])
        _ = try? await send(request)
    }

    func listProjects(token: String) async throws -> [TickTickProject] {
        let data = try await send(TickTickAPI.apiRequest("open/v1/project", token: token))
        guard let projects = try? JSONDecoder().decode([TickTickProject].self, from: data) else {
            throw TickTickError.invalidResponse
        }
        return projects.filter { $0.closed != true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func projectTasks(projectID: String, token: String) async throws -> [TickTickTask] {
        struct ProjectData: Decodable { var tasks: [TickTickTask]? }
        let data = try await send(TickTickAPI.apiRequest("open/v1/project/\(projectID)/data", token: token))
        guard let decoded = try? JSONDecoder().decode(ProjectData.self, from: data) else {
            throw TickTickError.invalidResponse
        }
        return decoded.tasks ?? []
    }

    /// Returns the new task's id, or "" when TickTick answers 201 without a body.
    func createTask(title: String, content: String, projectID: String, token: String) async throws -> String {
        let request = TickTickAPI.apiRequest("open/v1/task", token: token, method: "POST",
            body: try TickTickAPI.createTaskBody(title: title, content: content, projectID: projectID))
        let operation = PrivacyOperation(stage: .integration, data: [.text, .metadata],
                                         destination: .remote(url: TickTickAPI.apiBase, provider: .tickTick))
        let data = try await send(request, operation: operation)
        return (try? JSONDecoder().decode(TickTickTask.self, from: data))?.id ?? ""
    }

    private func send(_ request: URLRequest, operation: PrivacyOperation? = nil) async throws -> Data {
        let (data, response): (Data, URLResponse)
        if let operation {
            (data, response) = try await PrivacyHTTPTrace.data(for: request, operation: operation, session: session)
        } else {
            (data, response) = try await PrivacyHTTPTrace.untracedData(for: request, session: session)
        }
        guard let http = response as? HTTPURLResponse else { throw TickTickError.invalidResponse }
        if http.statusCode == 401 { throw TickTickError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw TickTickError.http(http.statusCode) }
        return data
    }
}
