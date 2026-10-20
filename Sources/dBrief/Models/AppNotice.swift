import Foundation

/// Something the user should know about, kept until they dismiss it. Replaces the single
/// `lastError` string: notices don't overwrite each other, carry where they came from
/// and which recording they concern, and can offer the action that resolves them.
struct AppNotice: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable { case error, warning, info }

    enum Source: Equatable, Sendable {
        case capture, review, processing, reprocessing, integrations, queue, imports, recovery, library
        /// Call sites that still set `AppState.lastError`.
        case general
    }

    let id: UUID
    let tone: Tone
    let message: String
    let source: Source
    let recordingURL: URL?
    let actions: [NoticeAction]

    init(id: UUID = UUID(), tone: Tone, message: String, source: Source,
         recordingURL: URL? = nil, actions: [NoticeAction] = []) {
        self.id = id
        self.tone = tone
        self.message = message
        self.source = source
        self.recordingURL = recordingURL
        self.actions = actions
    }
}

/// A button a notice offers.
enum NoticeAction: Equatable, Sendable {
    case openQueue
    case reviewIntegrations(URL)
    case openRecording(URL)
    case retryCaptureRecovery
    case showRecoveryFiles

    var title: String {
        switch self {
        case .openQueue: String(localized: "Show Queue & Recovery")
        case .reviewIntegrations: String(localized: "Integrations…")
        case .openRecording: String(localized: "Open Recording")
        case .retryCaptureRecovery: String(localized: "Retry Recovery")
        case .showRecoveryFiles: String(localized: "Show Files")
        }
    }
}

/// Newest first, a few at most, no duplicates.
struct NoticeList: Equatable, Sendable {
    static let limit = 5
    private(set) var items: [AppNotice] = []

    mutating func post(_ notice: AppNotice) {
        items.removeAll { $0.message == notice.message && $0.source == notice.source }
        items.insert(notice, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    mutating func dismiss(_ id: UUID) { items.removeAll { $0.id == id } }

    mutating func clear(source: AppNotice.Source) { items.removeAll { $0.source == source } }

    func items(for recordingURL: URL) -> [AppNotice] {
        let key = RecordingOwnership.key(for: recordingURL)
        return items.filter { $0.recordingURL.map { RecordingOwnership.key(for: $0) == key } ?? false }
    }
}
