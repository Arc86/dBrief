import Foundation

enum IntegrationDestination: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case obsidian
    case appleNotes
    case appleReminders
    case notion
    case evernote
    case googleKeep
    case oneNote
    case webhook
    case tickTick

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .obsidian: "Obsidian"
        case .appleNotes: "Apple Notes"
        case .appleReminders: "Apple Reminders"
        case .notion: "Notion"
        case .evernote: "Evernote"
        case .googleKeep: "Google Keep"
        case .oneNote: "Microsoft OneNote"
        case .webhook: "Webhook"
        case .tickTick: "TickTick"
        }
    }

    /// Destinations currently exposed to users. Untested integrations
    /// (Notion, Evernote, Google Keep, OneNote) are omitted until verified.
    /// TickTick appears only in builds stamped with its OAuth credentials.
    static var available: [IntegrationDestination] {
        available(tickTickConfigured: TickTickCredentials.bundled.isConfigured)
    }

    static func available(tickTickConfigured: Bool) -> [IntegrationDestination] {
        [.obsidian, .appleNotes, .appleReminders, .webhook] + (tickTickConfigured ? [.tickTick] : [])
    }
}

enum DeliveryField: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case audio
    case transcript
    case summary
    case tags
    case sentiment
    case actionItems
    case markdown
    case meetingInfo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .audio: "Audio"
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .tags: "Tags"
        case .sentiment: "Sentiment"
        case .actionItems: "Action Items"
        case .markdown: "Markdown"
        case .meetingInfo: "Meeting Info"
        }
    }

    /// Fields a destination can send. Only the webhook uploads the audio file;
    /// the others render text and would ignore an Audio toggle.
    static func options(includingAudio: Bool) -> [DeliveryField] {
        includingAudio ? allCases : allCases.filter { $0 != .audio }
    }
}

struct AppleNotesConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var accountName: String = ""
    var folderName: String = ""
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment, .meetingInfo]
}

struct AppleRemindersConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var listName: String = ""
}

struct TickTickConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    /// Nil sends to the Inbox.
    var projectID: String? = nil
    /// Display only; the id is what routes tasks.
    var projectName: String? = nil
}

enum NotionParentType: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case page
    case dataSource

    var id: String { rawValue }
}

struct NotionConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var tokenKeychainKey: String = KeychainSecretKey.notion.rawValue
    var parentType: NotionParentType = .dataSource
    var parentID: String = ""
    var titlePropertyName: String = "Name"
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment, .meetingInfo]
}

struct EvernoteConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var tokenKeychainKey: String = KeychainSecretKey.evernote.rawValue
    var apiBaseURL: String = "https://api.evernote.com"
    var notebookID: String = ""
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment, .meetingInfo]
}

struct GoogleKeepConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var tokenKeychainKey: String = KeychainSecretKey.googleKeep.rawValue
    var apiBaseURL: String = "https://keep.googleapis.com/v1"
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment, .meetingInfo]
}

struct OneNoteConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var tokenKeychainKey: String = KeychainSecretKey.oneNote.rawValue
    var graphBaseURL: String = "https://graph.microsoft.com/v1.0"
    var sectionID: String = ""
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment, .meetingInfo]
}

struct WebhookHeader: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var key: String = ""
    /// Runtime-only value; legacy decoding is retained solely for migration.
    var value: String = ""

    private enum CodingKeys: String, CodingKey { case id, key, value }

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
    }
}

struct WebhookConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var credentialID: UUID = UUID()
    /// The full destination can contain path/query credentials. Never serialize it.
    var url: String = ""
    var headers: [WebhookHeader] = []
    var timeoutSeconds: Double = 30
    var retryCount: Int = 1
    var fields: [DeliveryField] = [.transcript, .summary, .tags, .sentiment, .meetingInfo]
    var credentialsUnavailable = false
    var needsSecretMigration = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, credentialID, url, headers, timeoutSeconds, retryCount, fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Legacy metadata has no credential reference. Its placeholder identity
        // is replaced with a verified immutable revision during migration.
        credentialID = try container.decodeIfPresent(UUID.self, forKey: .credentialID)
            ?? UUID(uuidString: "09364B51-0CAC-42F5-895D-1065815026A5")!
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent([WebhookHeader].self, forKey: .headers) ?? []
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 1
        fields = try container.decodeIfPresent([DeliveryField].self, forKey: .fields)
            ?? [.transcript, .summary, .tags, .sentiment, .meetingInfo]
        needsSecretMigration = !container.contains(.credentialID) || container.contains(.url)
            || headers.contains { !$0.value.isEmpty }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(credentialID, forKey: .credentialID)
        try container.encode(headers, forKey: .headers)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(retryCount, forKey: .retryCount)
        try container.encode(fields, forKey: .fields)
    }
}

struct IntegrationSettings: Codable, Hashable, Sendable {
    var appleNotes = AppleNotesConfig()
    var appleReminders = AppleRemindersConfig()
    var notion = NotionConfig()
    var evernote = EvernoteConfig()
    var googleKeep = GoogleKeepConfig()
    var oneNote = OneNoteConfig()
    var webhook = WebhookConfig()
    var tickTick = TickTickConfig()
}

extension IntegrationSettings {
    /// Settings saved before a destination existed lack its key; decode each
    /// one leniently so adding a destination never resets the others.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        appleNotes = try container.decodeIfPresent(AppleNotesConfig.self, forKey: .appleNotes) ?? appleNotes
        appleReminders = try container.decodeIfPresent(AppleRemindersConfig.self, forKey: .appleReminders) ?? appleReminders
        notion = try container.decodeIfPresent(NotionConfig.self, forKey: .notion) ?? notion
        evernote = try container.decodeIfPresent(EvernoteConfig.self, forKey: .evernote) ?? evernote
        googleKeep = try container.decodeIfPresent(GoogleKeepConfig.self, forKey: .googleKeep) ?? googleKeep
        oneNote = try container.decodeIfPresent(OneNoteConfig.self, forKey: .oneNote) ?? oneNote
        webhook = try container.decodeIfPresent(WebhookConfig.self, forKey: .webhook) ?? webhook
        tickTick = try container.decodeIfPresent(TickTickConfig.self, forKey: .tickTick) ?? tickTick
    }
}

struct IntegrationDispatchResult: Sendable {
    enum Status: Sendable {
        case success
        case skipped
        case failed
    }

    let destination: IntegrationDestination
    let status: Status
    let message: String
    let remoteID: String?
    /// Action-item index → remote id for destinations that create one item per
    /// action item (TickTick). Kept on failure so a retry resumes.
    var createdItems: [Int: String]? = nil
}

enum IntegrationError: LocalizedError {
    case missingConfiguration(String)
    case invalidURL(String)
    case transport(statusCode: Int, body: String)
    case permissionDenied(String)
    case unsupported(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let message):
            message
        case .invalidURL(let value):
            "Invalid URL: \(value)"
        case .transport(let code, let body):
            "Request failed (\(code)): \(body)"
        case .permissionDenied(let reason):
            reason
        case .unsupported(let message):
            message
        case .executionFailed(let message):
            message
        }
    }
}

struct IntegrationContentBundle: Codable, Equatable, Sendable {
    let title: String
    let createdAt: Date
    let durationSeconds: TimeInterval
    let audioFileURL: URL
    let transcript: String?
    let summary: String?
    let actionItems: [String]
    let tags: [String]
    let sentiment: String?
    let markdown: String?
    /// Calendar event matched at record-start, carrying people/agenda/meeting metadata.
    let calendarEvent: CalendarEvent?
}
