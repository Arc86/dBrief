import Foundation

enum LibrarySmartView: String, Codable, CaseIterable, Sendable {
    case all, unfinishedActions, failedJobs, queuedInterrupted, recentlyProcessed, peopleThisMonth

    var title: String {
        switch self {
        case .all: "All Recordings"
        case .unfinishedActions: "Unfinished Actions"
        case .failedJobs: "Failed Jobs"
        case .queuedInterrupted: "Queued / Interrupted"
        case .recentlyProcessed: "Recently Processed"
        case .peopleThisMonth: "People I Met This Month"
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
