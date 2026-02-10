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
        }
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
        }
    }
}

struct AppleNotesConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var accountName: String = ""
    var folderName: String = ""
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment]
}

struct AppleRemindersConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var listName: String = ""
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
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment]
}

struct EvernoteConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var tokenKeychainKey: String = KeychainSecretKey.evernote.rawValue
    var apiBaseURL: String = "https://api.evernote.com"
    var notebookID: String = ""
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment]
}

struct GoogleKeepConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var tokenKeychainKey: String = KeychainSecretKey.googleKeep.rawValue
    var apiBaseURL: String = "https://keep.googleapis.com/v1"
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment]
}

struct OneNoteConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var tokenKeychainKey: String = KeychainSecretKey.oneNote.rawValue
    var graphBaseURL: String = "https://graph.microsoft.com/v1.0"
    var sectionID: String = ""
    var fields: [DeliveryField] = [.transcript, .summary, .actionItems, .tags, .sentiment]
}

struct WebhookHeader: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
}

struct WebhookConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var url: String = ""
    var headers: [WebhookHeader] = []
    var timeoutSeconds: Double = 30
    var retryCount: Int = 1
    var fields: [DeliveryField] = [.transcript, .summary, .tags, .sentiment]
}

struct IntegrationSettings: Codable, Hashable, Sendable {
    var appleNotes = AppleNotesConfig()
    var appleReminders = AppleRemindersConfig()
    var notion = NotionConfig()
    var evernote = EvernoteConfig()
    var googleKeep = GoogleKeepConfig()
    var oneNote = OneNoteConfig()
    var webhook = WebhookConfig()
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

struct IntegrationContentBundle: Sendable {
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
}
