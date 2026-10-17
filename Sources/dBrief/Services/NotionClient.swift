import Foundation

/// HTTP calls to Notion. Page writes carry meeting text, so they are recorded
/// in the recording's privacy receipt; reads and the connection test are not.
struct NotionClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func checkSecret(token: String) async throws {
        _ = try await send(NotionAPI.request("v1/users/me", token: token))
    }

    /// Every page and database shared with the integration (up to 1,000).
    func search(token: String) async throws -> [NotionDestination] {
        var destinations: [NotionDestination] = []
        var cursor: String?
        for _ in 0..<10 {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let page = try NotionAPI.parseSearch(await send(NotionAPI.request("v1/search", token: token,
                                                                              method: "POST", body: body)))
            destinations += page.destinations
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return destinations
    }

    func schema(dataSourceID: String, token: String) async throws -> NotionSchema {
        try NotionAPI.parseSchema(await send(NotionAPI.request("v1/data_sources/\(dataSourceID)", token: token)))
    }

    func createPage(parentType: NotionParentType, parentID: String, properties: [String: Any],
                    children: [[String: Any]], token: String) async throws -> String {
        let key = parentType == .dataSource ? "data_source_id" : "page_id"
        let body: [String: Any] = ["parent": ["type": key, key: parentID], "properties": properties, "children": children]
        let data = try await send(NotionAPI.request("v1/pages", token: token, method: "POST", body: body), traced: true)
        guard let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String else {
            throw NotionError.invalidResponse
        }
        return id
    }

    func append(_ children: [[String: Any]], to blockID: String, token: String) async throws {
        _ = try await send(NotionAPI.request("v1/blocks/\(blockID)/children", token: token, method: "PATCH",
                                             body: ["children": children]), traced: true)
    }

    /// Pages titled `title` that sit directly under `parentID`, most recently
    /// edited first. Recurring meeting titles can have many matches, so this
    /// pages through up to 500 results.
    func pages(titled title: String, under parentID: String, token: String) async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        for _ in 0..<5 {
            var body: [String: Any] = ["query": title, "page_size": 100,
                                       "filter": ["property": "object", "value": "page"],
                                       "sort": ["timestamp": "last_edited_time", "direction": "descending"]]
            if let cursor { body["start_cursor"] = cursor }
            let data = try await send(NotionAPI.request("v1/search", token: token, method: "POST", body: body))
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = object["results"] as? [[String: Any]] else { throw NotionError.invalidResponse }
            ids += results.compactMap { result in
                guard let id = result["id"] as? String, let parent = result["parent"] as? [String: Any],
                      let type = parent["type"] as? String, parent[type] as? String == parentID else { return nil }
                return id
            }
            guard object["has_more"] as? Bool == true, let next = object["next_cursor"] as? String else { break }
            cursor = next
        }
        return ids
    }

    /// Text of the page's first block, with a single request.
    func firstBlockText(of pageID: String, token: String) async throws -> String? {
        let data = try await send(NotionAPI.request("v1/blocks/\(pageID)/children", token: token,
                                                    query: [URLQueryItem(name: "page_size", value: "1")]))
        guard let first = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"] as? [[String: Any]])?.first,
              let type = first["type"] as? String else { return nil }
        return NotionAPI.plainText((first[type] as? [String: Any])?["rich_text"] as? [[String: Any]])
    }

    /// The page's top-level blocks: the first one's text and how many there are.
    func children(of pageID: String, token: String) async throws -> (firstText: String?, count: Int) {
        var firstText: String?
        var count = 0
        var cursor: String?
        for _ in 0..<50 {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "start_cursor", value: cursor)) }
            let data = try await send(NotionAPI.request("v1/blocks/\(pageID)/children", token: token, query: query))
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = object["results"] as? [[String: Any]] else { throw NotionError.invalidResponse }
            if count == 0, let first = results.first, let type = first["type"] as? String {
                firstText = NotionAPI.plainText((first[type] as? [String: Any])?["rich_text"] as? [[String: Any]])
            }
            count += results.count
            guard object["has_more"] as? Bool == true, let next = object["next_cursor"] as? String else { break }
            cursor = next
        }
        return (firstText, count)
    }

    private func send(_ request: URLRequest, traced: Bool = false) async throws -> Data {
        let (data, response): (Data, URLResponse)
        if traced {
            let operation = PrivacyOperation(stage: .integration, data: [.text, .metadata],
                                             destination: .remote(url: NotionAPI.apiBase, provider: .notion))
            (data, response) = try await PrivacyHTTPTrace.data(for: request, operation: operation, session: session)
        } else {
            (data, response) = try await PrivacyHTTPTrace.untracedData(for: request, session: session)
        }
        guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
        switch http.statusCode {
        case 200...299: return data
        case 401: throw NotionError.unauthorized
        case 403, 404: throw NotionError.notShared
        case 429: throw NotionError.rateLimited
        default: throw NotionError.http(http.statusCode)
        }
    }
}
