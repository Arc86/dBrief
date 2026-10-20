import Foundation

enum LibrarySmartView: String, Codable, CaseIterable, Sendable {
    case all, unfinishedActions, failedJobs, queuedInterrupted, recentlyProcessed, peopleThisMonth

    var title: String {
        switch self {
        case .all: String(localized: "All Recordings")
        case .unfinishedActions: String(localized: "Unfinished Actions")
        case .failedJobs: String(localized: "Needs Attention")
        case .queuedInterrupted: String(localized: "Queued / Interrupted")
        case .recentlyProcessed: String(localized: "Recently Processed")
        case .peopleThisMonth: String(localized: "People I Met This Month")
        }
    }

    var includesRecoveryWork: Bool { self == .failedJobs || self == .queuedInterrupted }
}

struct LibraryPersonGroup: Identifiable, Sendable {
    let person: LibraryPerson
    var recordings: [RecordingBrowserItem]
    var id: String { person.key }
}

struct LibrarySmartResults: Sendable {
    var recordings: [RecordingBrowserItem] = []
    var work: [LibraryWorkItem] = []
    var people: [LibraryPersonGroup] = []
}

@MainActor struct LibrarySmartViewSelection {
    static let key = "librarySmartView"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> LibrarySmartView {
        defaults.string(forKey: Self.key).flatMap(LibrarySmartView.init(rawValue:)) ?? .all
    }
    func save(_ view: LibrarySmartView) { defaults.set(view.rawValue, forKey: Self.key) }
}
