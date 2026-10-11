import CryptoKit
import Foundation

enum TodoistError: LocalizedError, Equatable, Sendable {
    case missingToken
    case unauthorized
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingToken: "Paste your Todoist API token first."
        case .unauthorized: "Todoist rejected the token. Paste a new one in Settings."
        case .invalidResponse: "Todoist returned a response dBrief couldn't read."
        case .http(let code): "Todoist returned an error (\(code))."
        }
    }
}

/// Per-command outcome of one /sync request.
struct TodoistSyncResult: Equatable, Sendable {
    var succeeded: Set<String> = []
    /// Command uuid → Todoist's error message.
    var errors: [String: String] = [:]
    /// temp_id → real task id.
    var tempIDMapping: [String: String] = [:]
}

/// Todoist API v1 constants and request builders (developer.todoist.com/api/v1).
/// Tasks are created through the Sync API because each command carries a
/// client uuid that Todoist never executes twice, which makes retries safe.
enum TodoistAPI {
    static let apiBase = URL(string: "https://api.todoist.com")!
    static let tokenSettingsURL = URL(string: "https://app.todoist.com/app/settings/integrations/developer")!
    static let maxCommandsPerRequest = 100

    /// Stable per delivery, settings and action item, so every retry resends the
    /// same id; a send accepted with changed settings gets new ids.
    static func commandUUID(deliveryID: UUID, digest: String, index: Int) -> String {
        var bytes = Array(SHA256.hash(data: Data("dbrief-todoist|\(deliveryID.uuidString)|\(digest)|\(index)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }

    /// `projectID == nil` adds the task to the Inbox.
    static func itemAdd(uuid: String, tempID: String, content: String, description: String,
                        projectID: String?) -> [String: Any] {
        var args = ["content": content, "description": description]
        if let projectID { args["project_id"] = projectID }
        return ["type": "item_add", "uuid": uuid, "temp_id": tempID, "args": args]
    }

    static func syncRequest(commands: [[String: Any]], token: String) throws -> URLRequest {
        var request = URLRequest(url: apiBase.appending(path: "api/v1/sync"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: commands, options: [.sortedKeys]), as: UTF8.self)
        request.httpBody = TickTickAPI.formBody([("commands", json)])
        return request
    }

    static func projectsRequest(token: String, cursor: String?) -> URLRequest {
        var components = URLComponents(url: apiBase.appending(path: "api/v1/projects"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "200")]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func parseSync(_ data: Data) throws -> TodoistSyncResult {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let statuses = object["sync_status"] as? [String: Any] else {
            throw TodoistError.invalidResponse
        }
        var result = TodoistSyncResult()
        for (uuid, status) in statuses {
            if status as? String == "ok" {
                result.succeeded.insert(uuid)
            } else {
                result.errors[uuid] = ((status as? [String: Any])?["error"] as? String) ?? "Todoist didn't accept this task."
            }
        }
        result.tempIDMapping = (object["temp_id_mapping"] as? [String: String]) ?? [:]
        return result
    }

    static func taskDescription(meetingTitle: String, date: Date,
                                locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return "From “\(title.isEmpty ? "Untitled meeting" : title)” · \(formatter.string(from: date)) — added by dBrief"
    }
}
