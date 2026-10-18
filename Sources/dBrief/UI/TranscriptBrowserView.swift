import SwiftUI
import AppKit

/// Two-pane transcript browser: a sidebar listing every recording and a detail
/// pane showing the selected recording's transcript (or chat). Mirrors the
/// spin-off project's `MainWindowView` layout.
struct TranscriptBrowserView: View {
    @Environment(AppContext.self) private var context
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ViewerPalette {
        ViewerThemeResolver.resolve(
            mode: appSettings.viewerAppearance.effectiveMode(systemIsDark: colorScheme == .dark),
            sourceHex: appSettings.viewerAppearance.sourceAccentHex, nonNeon: appSettings.reduceNeon)
    }

    @State private var searchText = ""
    @State private var statusFilter: LibraryRecordingStatus?
    @State private var library = RecordingLibraryModel()

    /// Whether the meeting-list sidebar is shown. Persisted so the choice
    /// survives relaunch.
    @AppStorage("transcriptSidebarOpen") private var sidebarOpen = true

    /// Whether the "Earlier" group is collapsed. Persisted across relaunches.
    @AppStorage("transcriptSidebarEarlierCollapsed") private var earlierCollapsed = false

    private var items: [RecordingBrowserItem] { library.items }
    private var queueDiscoveryFolders: [URL] {
        let profileFolders = appSettings.profiles.compactMap { profile -> URL? in
            guard let path = profile.overrides.recordingFolderPath,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Array(Set(([appSettings.recordingFolderURL] + profileFolders).map(\.standardizedFileURL)))
            .sorted { $0.path < $1.path }
    }
    @State private var selection: URL?
    @State private var selectedWork: LibraryWorkItem?
    @State private var detailIsProcessingPreview = false
    /// Stable `Recording` for the current selection. Built once per selection
    /// (not per render) so the detail view's identity and state — including its
    /// chat session — survive while chatting or playing back.
    @State private var detailRecording: Recording?
    /// The newest recording is opened once per window open, never after.
    @State private var didAutoSelect = false
    @FocusedValue(\.recordingViewer) private var viewer

    private var selectedItem: RecordingBrowserItem? {
        guard let selection else { return nil }
        return items.first { $0.url == selection }
    }

    /// The recording currently being **captured** (recording/paused), pinned at the top
    /// of the sidebar so it can be viewed live. `nil` when capture is idle.
    private var liveRecording: Recording? {
        guard appState.recordingState != .idle else { return nil }
        return appState.currentRecording
    }

    /// The recording being **processed** in the background, pinned separately so it can
    /// coexist with a concurrent capture. `nil` when no job is running. Guarded against
    /// duplicating the capture pin (they're always different recordings, but be safe).
    private var processingRecording: Recording? {
        guard let job = appState.processingJob else { return nil }
        if let live = liveRecording, live.id == job.recording.id { return nil }
        return job.recording
    }

    /// The finished capture open in the post-recording review form. Its recovery
    /// manifest is still "recoverable" until it is saved, so without this it showed
    /// in Queued / Interrupted as an interrupted recording.
    private var reviewingRecording: Recording? {
        appState.showPostRecordingSheet ? appState.currentRecording : nil
    }

    /// The index's work plus pending reprocess attempts, as the menu panel lists them.
    private var visibleWork: [LibraryWorkItem] {
        library.workMatches + LibraryWorkItem.reprocessing(
            recordingManager.reprocessingAttempts.map {
                .init(id: $0.id, audioURL: $0.audioURL, status: $0.status, message: $0.message, updatedAt: $0.updatedAt)
            },
            view: library.selectedView, activeAttemptID: appState.processingJob?.reprocessingAttemptID)
    }

    private var activeWorkIDs: Set<UUID> {
        Set([appState.processingJob?.id, processingRecording?.id, liveRecording?.id, reviewingRecording?.id].compactMap { $0 })
    }

    private var activeAudioURLs: Set<URL> {
        Set([liveRecording?.fileURL, liveRecording?.finalizedAudioURL,
             processingRecording?.fileURL, processingRecording?.finalizedAudioURL].compactMap { $0 })
    }

    private var viewSelection: Binding<LibrarySmartView> {
        Binding(get: { library.selectedView }, set: { library.selectView($0) })
    }

    private var navigationShell: some View {
        ViewerLibraryLayout(sidebarOpen: sidebarOpen, onToggleSidebar: { sidebarOpen.toggle() }) {
            sidebar
        } detail: {
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.canvas.color)
        }
        .frame(minWidth: 760, minHeight: 480)
        .modifier(ViewerWindowChrome())
        // Space plays and pauses wherever focus is, except while typing. Not a
        // menu equivalent: those also win over text input.
        .onKeyPress(.space) {
            guard !TextInputFocus.isActive, let toggle = viewer?.togglePlayback else { return .ignored }
            toggle()
            return .handled
        }
    }

    private var selectionLifecycle: some View {
        navigationShell
        .announcing(library.error, priority: .high)
        .announcing(searchResultSummary)
        .onAppear {
            library.updateActiveWork(ids: activeWorkIDs, audioURLs: activeAudioURLs)
            reload()
            applyPendingSelection()
            applyPendingLiveSelection()
            rebuildDetailRecording()
            selectNewestIfNeeded()
        }
        .onChange(of: selection) { _, value in
            if value != nil { selectedWork = nil }
            rebuildDetailRecording()
        }
        .onChange(of: searchText) { _, value in
            selectedWork = nil
            library.search(text: value, status: statusFilter)
        }
        .onChange(of: statusFilter) { _, value in
            selectedWork = nil
            library.search(text: searchText, status: value)
        }
        .onChange(of: library.selectedView) { _, _ in selectedWork = nil }
        .onChange(of: activeWorkIDs) { _, _ in updateActiveWork() }
        .onChange(of: activeAudioURLs) { _, _ in updateActiveWork() }
        .onChange(of: library.queryRevision) { _, _ in
            if let selectedWork, library.error == nil {
                self.selectedWork = visibleWork.first { $0.id == selectedWork.id }
            }
            selectNewestIfNeeded()
        }
        .onChange(of: queueDiscoveryFolders) { _, _ in reload() }
        .onChange(of: library.items) { _, _ in rebuildDetailRecording() }
        .onChange(of: library.refreshedRevision) { _, _ in
            if let selection, !items.contains(where: { $0.url == selection }),
               liveRecording?.fileURL != selection, processingRecording?.fileURL != selection {
                self.selection = nil
            }
            rebuildDetailRecording()
        }
    }

    var body: some View {
        Group {
            if recordingManager.reprocessingRecoveryReady { browserContent }
            else { ReprocessingRecoveryView() }
        }
        .onChange(of: recordingManager.reprocessingRecoveryReady) { _, ready in
            if ready { reload(); rebuildDetailRecording() }
            else { library.suspend(); detailRecording = nil }
        }
        .modifier(ViewerAppearanceScope(settings: appSettings))
    }

    private var browserContent: some View {
        selectionLifecycle
        .onReceive(NotificationCenter.default.publisher(for: .recordingLibraryChanged).receive(on: RunLoop.main)) { _ in
            if recordingManager.reprocessingRecoveryReady { library.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).receive(on: RunLoop.main)) { _ in
            library.refreshTimeContext()
            if recordingManager.reprocessingRecoveryReady { library.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            library.refreshTimeContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in
            library.refreshTimeContext()
        }
        .task(id: appSettings.effectiveRecordingFolderURL) {
            guard recordingManager.reprocessingRecoveryReady else { return }
            library.open(appSettings.effectiveRecordingFolderURL, configuredQueueFolders: queueDiscoveryFolders)
            // Discover external sidecar edits and file moves while this window is
            // open. Unchanged files are only stat'ed; their contents stay cached.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if recordingManager.reprocessingRecoveryReady { library.refresh() }
            }
        }
        .onChange(of: appState.pendingTranscriptSelectionURL) { _, _ in
            applyPendingSelection()
        }
        .onChange(of: appState.pendingLiveTranscriptSelection) { _, _ in
            applyPendingLiveSelection()
        }
        .onChange(of: appState.recordingState) { _, newState in
            // Reload once a capture finishes so it appears as a normal entry.
            if newState == .idle { reload() }
            rebuildDetailRecording()
        }
        .onChange(of: appState.isProcessing) { _, nowProcessing in
            // Processing no longer changes `recordingState`, so reload when a background
            // job finishes so the completed recording appears as a normal entry.
            if !nowProcessing { reload() }
            rebuildDetailRecording()
        }
    }

    // MARK: - Shell panes

    /// The same Remove actions the menu panel's Queue & Recovery offers.
    private func removeAction(for work: LibraryWorkItem) -> (@MainActor () async -> Void)? {
        switch work.target {
        case .queue:
            guard let audio = work.audioURL else { return nil }
            return { await recordingManager.removeQueuedItem(audio); library.refresh() }
        case .recovery, .delivery:
            return { await recordingManager.dismissRecoveryItem(work.recoveryID); library.refresh() }
        case .reprocess:
            return {
                guard DestructiveConfirmation.confirm("Discard this reprocess?",
                    message: "The recording's current results stay. The unfinished reprocess can't be resumed afterwards.",
                    button: "Discard") else { return }
                await recordingManager.discardReprocessing(work.recoveryID); library.refresh()
            }
        case .capture:
            return nil
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        if let work = selectedWork {
            LibraryWorkDetailView(item: work,
                disabledReason: recordingManager.libraryWorkBlockMessage(work.target)
                    ?? (library.isQuerying || library.error != nil ? "The library is updating. Try again in a moment." : nil),
                remove: removeAction(for: work),
                openRecording: work.audioURL.map { url in { appState.pendingTranscriptSelectionURL = url } }) {
                try await recordingManager.performLibraryWork(work)
                if recordingManager.reprocessingRecoveryReady { library.refresh() }
            }
            .id(work.id)
        } else if let recording = detailRecording {
            TranscriptDetailView(
                recording: recording,
                onDeleted: { handleDeleted(recording.fileURL) }
            )
            .equatable()
            .id(recording.fileURL)
        } else {
            ContentUnavailableView(
                "Select a Recording",
                systemImage: "text.bubble",
                description: Text("Choose a recording to view its transcript."))
        }
    }

    // MARK: - Sidebar

    /// SQL full-text results, queried without decoding canonical sidecars.
    private var filteredItems: [RecordingBrowserItem] {
        library.matches
    }

    private var thisWeekItems: [RecordingBrowserItem] {
        let cal = Calendar.current
        return filteredItems.filter { cal.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }
    }

    private var earlierItems: [RecordingBrowserItem] {
        let cal = Calendar.current
        return filteredItems.filter { !cal.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }
    }

    private var sidebar: some View {
        ViewerLibrarySidebar(
            searchText: $searchText,
            selectedView: viewSelection,
            statusFilter: $statusFilter,
            isLoading: library.showsInitialLoading,
            isRefreshing: library.isRefreshing,
            error: library.error,
            emptyMessage: sidebarEmptyMessage,
            isRecordEnabled: appState.isIdle,
            onRecord: {
                Task { await recordingManager.requestRecording() }
            },
            onRefresh: reload,
            onRebuildSearchIndex: { library.refresh(rebuild: true) },
            onSettings: { openWindow(id: "settings") },
            selectedRowID: selectedWork.map { AnyHashable($0.id) } ?? selection.map(rowID(for:)),
            selectionKey: selectedWork.map { AnyHashable($0.id) } ?? selection.map { AnyHashable($0) },
            selectedTitle: selectedSidebarTitle,
            onMove: moveSelection(by:)
        ) { statusMenu in
            if liveRecording != nil || processingRecording != nil {
                LibrarySectionHeader(title: "In Progress")
                // Pinned ids must differ from the library rows' (their URL): the lazy
                // stack would otherwise keep showing this pinned row in the list
                // row for the same recording once processing finishes.
                if let live = liveRecording {
                    LiveSidebarRow(recording: live, isProcessing: false,
                        isSelected: selection == live.fileURL,
                        onTap: { selectRecording(live.fileURL) })
                        .id(PinnedRowID.live(live.fileURL))
                }
                if let proc = processingRecording {
                    LiveSidebarRow(recording: proc, isProcessing: true,
                        isSelected: selection == proc.fileURL,
                        onTap: { selectRecording(proc.fileURL) })
                        .id(PinnedRowID.processing(proc.fileURL))
                }
            }
            smartResults(statusMenu: statusMenu)
        }
    }

    private var emptyDescription: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matches for this search."
        }
        if let statusFilter {
            return "No recordings with status \(statusFilter.title)."
        }
        return switch library.selectedView {
        case .all: "No recordings in this folder."
        case .unfinishedActions: "No unfinished actions."
        case .failedJobs: "No failed jobs."
        case .queuedInterrupted: "No queued or interrupted work."
        case .recentlyProcessed: "No recordings processed in the last seven days."
        case .peopleThisMonth: "No named people in this month's recordings."
        }
    }

    private var sidebarEmptyMessage: String? {
        guard !library.hasMatches, visibleWork.isEmpty,
              liveRecording == nil,
              processingRecording == nil,
              !library.showsInitialLoading,
              library.error == nil else { return nil }
        return emptyDescription
    }

    @ViewBuilder private func smartResults(statusMenu: ViewerSidebarStatusFilterMenu) -> some View {
        switch library.selectedView {
        case .all:
            Group {
                let thisWeek = thisWeekItems
                let earlier = earlierItems
                LibrarySectionHeader(title: "This week", count: thisWeek.isEmpty ? nil : thisWeek.count) { statusMenu }
                ForEach(thisWeek) { row(for: $0) }
                if thisWeek.isEmpty, !earlier.isEmpty {
                    LibrarySidebarNote(text: "Nothing recorded this week.")
                }

                if !earlier.isEmpty {
                    LibraryCollapsibleSectionHeader(title: "Earlier", count: earlier.count, collapsed: $earlierCollapsed)
                        .padding(.top, 6)

                    if !earlierCollapsed {
                        ForEach(earlier) { row(for: $0) }
                    }
                }
            }
        case .unfinishedActions:
            Group {
                LibrarySectionHeader(title: "Unfinished actions", count: filteredItems.count) { statusMenu }
                ForEach(filteredItems) { row(for: $0) }
            }
        case .recentlyProcessed:
            Group {
                LibrarySectionHeader(title: "Recently processed", count: filteredItems.count) { statusMenu }
                // Preserve SQL processing-time ordering for Recently Processed.
                ForEach(filteredItems) { row(for: $0) }
            }
        case .failedJobs, .queuedInterrupted:
            Group {
                LibrarySectionHeader(
                    title: library.selectedView.title,
                    count: visibleWork.count
                )
                ForEach(visibleWork) { item in
                    LibraryWorkRow(item: item, isSelected: selectedWork?.id == item.id) {
                        selection = nil
                        detailRecording = nil
                        selectedWork = item
                    }
                }
            }
        case .peopleThisMonth:
            Group {
                LibrarySectionHeader(title: "People this month", count: library.peopleGroups.count) { statusMenu }
                ForEach(library.peopleGroups) { group in
                    DisclosureGroup {
                        ForEach(group.recordings) { row(for: $0) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.secondary.color)
                                .accessibilityHidden(true)
                            Text(group.person.name)
                                .uiFont(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.text.color)
                                .lineLimit(1)
                            Spacer(minLength: 3)
                            Text("\(group.recordings.count)")
                                .uiFont(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(palette.secondary.color)
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(palette.accentText.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private enum PinnedRowID: Hashable {
        case live(URL), processing(URL)
    }

    /// The sidebar row id for a selected recording, so scrolling finds pinned rows too.
    private func rowID(for url: URL) -> AnyHashable {
        if url == liveRecording?.fileURL { return AnyHashable(PinnedRowID.live(url)) }
        if url == processingRecording?.fileURL { return AnyHashable(PinnedRowID.processing(url)) }
        return AnyHashable(url)
    }

    private func selectRecording(_ url: URL) {
        selectedWork = nil
        selection = url
    }

    /// Recording rows in the order the sidebar shows them, pinned work first.
    /// Collapsed "Earlier" rows are skipped, as the keys can't reach them visibly.
    private var visibleRecordingURLs: [URL] {
        var urls = [liveRecording?.fileURL, processingRecording?.fileURL].compactMap { $0 }
        switch library.selectedView {
        case .all:
            urls += thisWeekItems.map(\.url)
            if !earlierCollapsed { urls += earlierItems.map(\.url) }
        case .unfinishedActions, .recentlyProcessed:
            urls += filteredItems.map(\.url)
        case .peopleThisMonth:
            for url in library.peopleGroups.flatMap({ $0.recordings.map(\.url) }) where !urls.contains(url) {
                urls.append(url)
            }
        case .failedJobs, .queuedInterrupted:
            break
        }
        return urls
    }

    /// "3 recordings found" while searching, for VoiceOver.
    private var searchResultSummary: String? {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty, !library.showsInitialLoading else { return nil }
        let count = filteredItems.count + library.workMatches.count
        return count == 0 ? "No recordings found" : "\(count) \(count == 1 ? "recording" : "recordings") found"
    }

    /// The selected row's title and date, for VoiceOver.
    private var selectedSidebarTitle: String? {
        if let selectedWork { return "\(selectedWork.title), \(selectedWork.date.formatted(date: .abbreviated, time: .shortened))" }
        guard let selection else { return nil }
        if selection == liveRecording?.fileURL { return "Recording in progress" }
        if selection == processingRecording?.fileURL { return "Recording being processed" }
        guard let item = items.first(where: { $0.url == selection }) else { return nil }
        return "\(item.title), \(item.date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func moveSelection(by offset: Int) {
        defer { if let title = selectedSidebarTitle { appState.announcer.announce(title) } }
        switch library.selectedView {
        case .failedJobs, .queuedInterrupted:
            let ids = visibleWork.map(\.id)
            guard let id = LibraryKeyboardNavigation.step(ids, from: selectedWork?.id, by: offset),
                  let item = visibleWork.first(where: { $0.id == id }) else { return }
            selection = nil
            detailRecording = nil
            selectedWork = item
        default:
            guard let url = LibraryKeyboardNavigation.step(visibleRecordingURLs, from: selection, by: offset)
            else { return }
            selectRecording(url)
        }
    }

    /// Opening the library shows the top recording instead of an empty pane,
    /// unless something asked for a specific one.
    private func selectNewestIfNeeded() {
        guard !didAutoSelect, library.queryRevision > 0 else { return }
        didAutoSelect = true
        guard selection == nil, selectedWork == nil, appState.pendingTranscriptSelectionURL == nil,
              appState.pendingLiveTranscriptSelection == nil else { return }
        let pinned = Set([liveRecording?.fileURL, processingRecording?.fileURL].compactMap { $0 })
        if let newest = visibleRecordingURLs.first(where: { !pinned.contains($0) }) {
            selection = newest
        }
    }

    private func updateActiveWork() {
        library.updateActiveWork(ids: activeWorkIDs, audioURLs: activeAudioURLs)
    }

    private func row(for item: RecordingBrowserItem) -> some View {
        LibraryRecordingRow(item: item, isSelected: selection == item.url,
                            onSelect: { selectRecording(item.url) })
            .equatable()
    }

    // MARK: - Helpers

    private func reload() {
        guard recordingManager.reprocessingRecoveryReady else { return }
        library.open(appSettings.effectiveRecordingFolderURL, configuredQueueFolders: queueDiscoveryFolders)
    }

    private func rebuildDetailRecording() {
        // Selecting a pinned in-progress entry shows that recording object directly.
        if let live = liveRecording, selection == live.fileURL {
            detailIsProcessingPreview = false
            if detailRecording !== live { detailRecording = live }
            return
        }
        if let proc = processingRecording, selection == proc.fileURL {
            detailIsProcessingPreview = true
            if detailRecording !== proc { detailRecording = proc }
            return
        }
        if let item = selectedItem {
            // On completion, failure or Stop, leave the staged object behind and
            // reload the published recording, even though its URL is unchanged.
            if detailIsProcessingPreview || detailRecording?.fileURL != item.url {
                detailRecording = Self.makeRecording(from: item)
            }
        } else {
            detailRecording = nil
        }
        detailIsProcessingPreview = false
    }

    private func applyPendingSelection() {
        guard let pending = appState.pendingTranscriptSelectionURL else { return }
        if !items.contains(where: { $0.url == pending }) { reload() }
        selection = pending
        appState.pendingTranscriptSelectionURL = nil
    }

    private func applyPendingLiveSelection() {
        guard let target = appState.pendingLiveTranscriptSelection else { return }
        // Each Live button opens its own recording, falling back to the other one.
        if let url = target.url(capture: liveRecording?.fileURL, processing: processingRecording?.fileURL) {
            selection = url
        }
        // The URL may already be selected, so onChange(selection) need not fire.
        // Switch from the published recording to this job's staged object anyway.
        selectedWork = nil
        rebuildDetailRecording()
        appState.pendingLiveTranscriptSelection = nil
    }

    private func handleDeleted(_ url: URL) {
        // Like Finder and Mail, the next row (else the previous) takes the selection.
        let next = LibraryKeyboardNavigation.successor(of: url, in: visibleRecordingURLs)
        library.refresh()
        if selection == url { selection = next }
        if detailRecording?.fileURL == url { detailRecording = nil }
    }

    fileprivate static func makeRecording(from item: RecordingBrowserItem) -> Recording {
        let recording = Recording(
            date: item.date,
            fileURL: item.url,
            duration: item.duration,
            fileSize: item.size,
            meetingTitleDraft: item.title,
            finalizedAudioURL: item.url
        )
        // Carry the persisted AI title so the detail view's navigation title
        // reflects it after post-processing (not the stale filename). See #71.
        recording.generatedTitle = item.generatedTitle
        // …and the meeting's people, so assigning a speaker offers the names from this
        // meeting (participants + calendar attendees) and not just the voice library.
        recording.participants = item.meetingNames
        return recording
    }
}

/// A library row plus the shared recording context menu. Equatable over the row's data,
/// so a selection change re-renders only the two rows whose `isSelected` flipped
/// instead of every row and every context menu (each menu wraps a fresh
/// `Recording` and a `ReprocessingMenu`, which `.contextMenu` builds eagerly).
private struct LibraryRecordingRow: View, Equatable {
    let item: RecordingBrowserItem
    let isSelected: Bool
    /// Not compared: it only selects `item.url`, which `item` already covers.
    let onSelect: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        SidebarRecordingRow(item: item, isSelected: isSelected, onTap: onSelect)
            .contextMenu {
                RecordingContextMenu(recording: TranscriptBrowserView.makeRecording(from: item),
                                     hasTranscript: item.hasTranscript, open: onSelect)
            }
    }
}
