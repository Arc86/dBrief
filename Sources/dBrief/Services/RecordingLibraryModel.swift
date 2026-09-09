import Foundation

/// UI coordination only. Cancelling a search never cancels an index refresh;
/// old queries and old folders cannot publish over newer user input.
@MainActor @Observable
final class RecordingLibraryModel {
    private(set) var items: [RecordingBrowserItem] = []
    private(set) var matches: [RecordingBrowserItem] = []
    private(set) var workMatches: [LibraryWorkItem] = []
    private(set) var peopleGroups: [LibraryPersonGroup] = []
    private(set) var selectedView: LibrarySmartView
    private(set) var isQuerying = false
    private(set) var queryRevision = 0
    private(set) var isRefreshing = false
    private var hasLoadedResults = false
    var showsInitialLoading: Bool { !hasLoadedResults && error == nil && (isRefreshing || isQuerying) }
    /// Only advances after complete discovery, never when publishing a warm
    /// cache. Selection may be validated against this revision's item list.
    private(set) var refreshedRevision = 0
    var error: String? { queryError ?? refreshError }
    var hasMatches: Bool { !matches.isEmpty || !workMatches.isEmpty || !peopleGroups.isEmpty }
    private var queryError: String?
    private var refreshError: String?
    private let selectionStore: LibrarySmartViewSelection
    private var excludedWorkIDs: Set<UUID> = []
    private var excludedAudioURLs: Set<URL> = []
    private var folder: URL?
    private var configuredQueueFolders: [URL] = []
    private var text = ""
    private var status: LibraryRecordingStatus?
    private var queryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var pendingRebuild = false
    private let index: LibraryIndex

    init(index: LibraryIndex = .shared, selectionStore: LibrarySmartViewSelection = .init()) {
        self.index = index
        self.selectionStore = selectionStore
        selectedView = selectionStore.load()
    }

    /// Prevent an in-flight read from publishing across a result-set replacement.
    func suspend() {
        refreshTask?.cancel()
        queryTask?.cancel()
        refreshTask = nil
        queryTask = nil
        isRefreshing = false
        isQuerying = false
        pendingRefresh = false
        pendingRebuild = false
    }

    func open(_ folder: URL, configuredQueueFolders: [URL] = []) {
        self.configuredQueueFolders = configuredQueueFolders
        guard self.folder != folder else { refresh(); return }
        refreshTask?.cancel()
        queryTask?.cancel()
        self.folder = folder
        items = []
        hasLoadedResults = false
        clearMatches()
        queryError = nil
        refreshError = nil
        isQuerying = false
        isRefreshing = true
        pendingRefresh = false
        pendingRebuild = false
        refreshTask = Task {
            // A warm open displays cached summaries before walking directories.
            if let cached = try? await index.search(in: folder), !Task.isCancelled {
                items = cached
                search(text: text, status: status)
            }
            guard !Task.isCancelled else { return }
            refreshTask = nil
            refresh()
        }
    }

    func selectView(_ view: LibrarySmartView) {
        guard selectedView != view else { return }
        selectedView = view
        selectionStore.save(view)
        query(invalidateResults: true)
    }

    func updateActiveWork(ids: Set<UUID>, audioURLs: Set<URL>) {
        let urls = Set(audioURLs.map(\.standardizedFileURL))
        guard ids != excludedWorkIDs || urls != excludedAudioURLs else { return }
        excludedWorkIDs = ids
        excludedAudioURLs = urls
        query(invalidateResults: true)
    }

    /// Activation/calendar notifications re-evaluate time windows even if no
    /// sidecar changed. Explicit dates also make boundary behavior reproducible.
    func refreshTimeContext(now: Date = Date(), calendar: Calendar = .current) {
        query(invalidateResults: false, now: now, calendar: calendar)
    }

    func search(text: String, status: LibraryRecordingStatus?) {
        let changed = text != self.text || status != self.status
        self.text = text
        self.status = status
        query(invalidateResults: changed)
    }

    private func clearMatches() {
        matches = []
        workMatches = []
        peopleGroups = []
    }

    private func query(invalidateResults: Bool, now: Date = Date(), calendar: Calendar = .current) {
        queryTask?.cancel()
        if invalidateResults {
            clearMatches()
            hasLoadedResults = false
        }
        queryError = nil
        guard let folder else { return }
        isQuerying = true
        let view = selectedView
        let queryText = text
        let queryStatus = status
        let ids = excludedWorkIDs
        let urls = excludedAudioURLs
        queryTask = Task {
            do {
                let results = try await index.smartResults(in: folder, view: view, text: queryText, status: queryStatus,
                    now: now, calendar: calendar, excludingWorkIDs: ids, excludingAudioURLs: urls)
                guard !Task.isCancelled else { return }
                if matches != results.recordings { matches = results.recordings }
                workMatches = results.work
                peopleGroups = results.people
                hasLoadedResults = true
                queryRevision += 1
            } catch {
                guard !Task.isCancelled else { return }
                queryError = error.localizedDescription
            }
            isQuerying = false
            queryTask = nil
        }
    }

    func refresh(rebuild: Bool = false) {
        guard let folder else { return }
        if refreshTask != nil {
            pendingRefresh = true
            pendingRebuild = pendingRebuild || rebuild
            return
        }
        isRefreshing = true
        let queueFolders = configuredQueueFolders
        refreshTask = Task {
            do {
                try await index.refresh(in: folder, configuredQueueFolders: queueFolders, rebuild: rebuild)
                let loaded = try await index.search(in: folder)
                guard !Task.isCancelled else { return }
                if items != loaded { items = loaded }
                refreshError = nil
                refreshedRevision += 1
                search(text: text, status: status)
            } catch {
                guard !Task.isCancelled else { return }
                refreshError = error.localizedDescription
            }
            isRefreshing = false
            refreshTask = nil
            if pendingRefresh {
                let rebuild = pendingRebuild
                pendingRefresh = false
                pendingRebuild = false
                refresh(rebuild: rebuild)
            }
        }
    }
}
