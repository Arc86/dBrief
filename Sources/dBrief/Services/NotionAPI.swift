import Foundation

enum NotionError: LocalizedError, Equatable, Sendable {
    case missingToken
    case missingDestination
    case unauthorized
    case notShared
    case rateLimited
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingToken: "Paste your Notion integration secret first."
        case .missingDestination: "Choose a Notion page or database to send notes to."
        case .unauthorized: "Notion rejected the integration secret. Paste a new one in Settings."
        case .notShared: "Notion can't see that page or database. Connect it to your integration (••• → Connections)."
        case .rateLimited: "Notion is limiting requests right now. Try again in a minute."
        case .invalidResponse: "Notion returned a response dBrief couldn't read."
        case .http(let code): "Notion returned an error (\(code))."
        }
    }
}

/// A page or database (data source) the integration can write into.
struct NotionDestination: Hashable, Sendable {
    enum Kind: String, Sendable {
        case page
        case dataSource = "data_source"
    }
    let kind: Kind
    let id: String
    let name: String
}

/// Columns of a database (data source) that dBrief fills, found by type.
struct NotionSchema: Equatable, Sendable {
    let titleProperty: String
    let dateProperty: String?
    let tagsProperty: String?
}

/// Notion API constants, request builders, parsers and the page layout.
/// Content is sent as blocks: Notion allows 2,000 characters per text object
/// and 100 blocks per request, so long text is split and pages are written in
/// batches (see `IntegrationDispatchService+Notion.swift`).
enum NotionAPI {
    static let apiBase = URL(string: "https://api.notion.com")!
    static let version = "2026-03-11"
    static let integrationsURL = URL(string: "https://www.notion.so/profile/integrations")!
    static let maxTextLength = 2_000
    static let maxBlocksPerRequest = 100

    static func reference(for batchID: UUID) -> String {
        String(batchID.uuidString.lowercased().prefix(8))
    }

    static func request(_ path: String, token: String, method: String = "GET",
                        body: [String: Any]? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        var components = URLComponents(url: apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    // MARK: - Page layout

    static func blocks(for bundle: IntegrationContentBundle, fields: [DeliveryField], reference: String,
                       locale: Locale = .current, timeZone: TimeZone = .current) -> [[String: Any]] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var blocks = [block("paragraph", "\(formatter.string(from: bundle.createdAt)) · \(duration(bundle.durationSeconds)) — added by dBrief (ref \(reference))")]
        if fields.contains(.meetingInfo), let names = bundle.calendarEvent?.attendeeNames, !names.isEmpty {
            blocks.append(block("paragraph", "Participants: \(names.joined(separator: ", "))"))
        }
        if fields.contains(.summary), let summary = nonEmpty(bundle.summary) {
            blocks.append(block("heading_2", "Summary"))
            blocks += summaryBlocks(summary)
        }
        let actions = bundle.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if fields.contains(.actionItems), !actions.isEmpty {
            blocks.append(block("heading_2", "Action items"))
            blocks += actions.flatMap { split($0) }.map { block("to_do", $0, extra: ["checked": false]) }
        }
        let tags = bundle.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if fields.contains(.tags), !tags.isEmpty {
            blocks.append(block("heading_2", "Tags"))
            blocks += split(tags.joined(separator: ", ")).map { block("paragraph", $0) }
        }
        if fields.contains(.sentiment), let sentiment = nonEmpty(bundle.sentiment) {
            blocks.append(block("heading_2", "Sentiment"))
            blocks += split(sentiment).map { block("paragraph", $0) }
        }
        if fields.contains(.transcript), let transcript = nonEmpty(bundle.transcript) {
            blocks.append(block("heading_2", "Transcript"))
            blocks += paragraphs(transcript).map { block("paragraph", $0) }
        }
        return blocks
    }

    /// Blank-line separated paragraphs; lines starting with -, * or • become bullets.
    private static func summaryBlocks(_ summary: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for section in summary.components(separatedBy: "\n\n") {
            var prose: [String] = []
            func flush() {
                let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { blocks += split(text).map { block("paragraph", $0) } }
                prose = []
            }
            for line in section.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let marker = ["- ", "* ", "• "].first(where: { trimmed.hasPrefix($0) }) {
                    flush()
                    let item = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty { blocks += split(item).map { block("bulleted_list_item", $0) } }
                } else {
                    prose.append(line)
                }
            }
            flush()
        }
        return blocks
    }

    /// Whole lines packed into paragraphs of at most `maxTextLength` characters.
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            for piece in split(line) {
                if current.isEmpty {
                    current = piece
                } else if current.count + 1 + piece.count <= maxTextLength {
                    current += "\n" + piece
                } else {
                    result.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Splits text into pieces of at most `maxTextLength`, at whitespace when possible.
    static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > maxTextLength {
            let window = rest.prefix(maxTextLength)
            let cut = window.lastIndex(where: { $0.isWhitespace }).map { rest.index(after: $0) } ?? window.endIndex
            pieces.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...]
        }
        let last = String(rest).trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { pieces.append(last) }
        return pieces
    }

    private static func block(_ type: String, _ text: String, extra: [String: Any] = [:]) -> [String: Any] {
        var content: [String: Any] = ["rich_text": [richText(text)]]
        content.merge(extra) { $1 }
        return ["object": "block", "type": type, type: content]
    }

    private static func richText(_ text: String) -> [String: Any] {
        ["type": "text", "text": ["content": text]]
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.down)))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    // MARK: - Page properties

    /// A child page only has a title; a database entry also gets its Date and
    /// Tags columns when the database has them.
    static func properties(title: String, schema: NotionSchema?, date: Date, tags: [String]) -> [String: Any] {
        let titleValue: [String: Any] = ["title": [richText(String(title.prefix(maxTextLength)))]]
        guard let schema else { return ["title": titleValue] }
        var properties: [String: Any] = [schema.titleProperty: titleValue]
        if let dateProperty = schema.dateProperty {
            properties[dateProperty] = ["date": ["start": ISO8601DateFormatter().string(from: date)]]
        }
        if let tagsProperty = schema.tagsProperty {
            var seen = Set<String>()
            let names = tags.compactMap { tag -> String? in
                // Notion option names can't contain commas and are limited to 100 characters.
                let name = String(tag.replacingOccurrences(of: ",", with: " ")
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(100))
                return name.isEmpty || !seen.insert(name.lowercased()).inserted ? nil : name
            }
            properties[tagsProperty] = ["multi_select": names.prefix(100).map { ["name": $0] }]
        }
        return properties
    }

    // MARK: - Parsing

    static func parseSchema(_ data: Data) throws -> NotionSchema {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let properties = object["properties"] as? [String: Any] else { throw NotionError.invalidResponse }
        let typed = properties.compactMap { name, value -> (name: String, type: String)? in
            guard let type = (value as? [String: Any])?["type"] as? String else { return nil }
            return (name, type)
        }.sorted { $0.name < $1.name }
        guard let title = typed.first(where: { $0.type == "title" })?.name else { throw NotionError.invalidResponse }
        func pick(_ type: String, preferring preferred: String) -> String? {
            let candidates = typed.filter { $0.type == type }
            if let named = candidates.first(where: { $0.name.lowercased() == preferred }) { return named.name }
            return candidates.count == 1 ? candidates[0].name : nil
        }
        return NotionSchema(titleProperty: title, dateProperty: pick("date", preferring: "date"),
                            tagsProperty: pick("multi_select", preferring: "tags"))
    }

    struct SearchPage: Equatable, Sendable {
        var destinations: [NotionDestination]
        var nextCursor: String?
    }

    /// Pages and databases the integration can see. Database rows are skipped:
    /// they make poor parents for meeting notes.
    static func parseSearch(_ data: Data) throws -> SearchPage {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { throw NotionError.invalidResponse }
        let destinations = results.compactMap { result -> NotionDestination? in
            guard let id = result["id"] as? String, result["in_trash"] as? Bool != true,
                  result["archived"] as? Bool != true else { return nil }
            switch result["object"] as? String {
            case "page":
                let parent = (result["parent"] as? [String: Any])?["type"] as? String
                guard parent != "data_source_id", parent != "database_id" else { return nil }
                let properties = result["properties"] as? [String: Any] ?? [:]
                let title = properties.values.compactMap { $0 as? [String: Any] }
                    .first { $0["type"] as? String == "title" }?["title"] as? [[String: Any]]
                return NotionDestination(kind: .page, id: id, name: plainText(title) ?? "Untitled")
            case "data_source":
                return NotionDestination(kind: .dataSource, id: id,
                                         name: plainText(result["title"] as? [[String: Any]]) ?? "Untitled database")
            default:
                return nil
            }
        }
        let more = object["has_more"] as? Bool ?? false
        return SearchPage(destinations: destinations, nextCursor: more ? object["next_cursor"] as? String : nil)
    }

    static func plainText(_ richText: [[String: Any]]?) -> String? {
        let text = (richText ?? []).compactMap { $0["plain_text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
