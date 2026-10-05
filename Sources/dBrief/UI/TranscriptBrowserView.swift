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

    private var activeWorkIDs: Set<UUID> {
        Set([appState.processingJob?.id, processingRecording?.id, liveRecording?.id].compactMap { $0 })
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
    }

    private var selectionLifecycle: some View {
        navigationShell
        .onAppear {
            library.updateActiveWork(ids: activeWorkIDs, audioURLs: activeAudioURLs)
            reload()
            applyPendingSelection()
            applyPendingLiveSelection()
            rebuildDetailRecording()
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
                self.selectedWork = library.workMatches.first { $0.id == selectedWork.id }
            }
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

    @ViewBuilder
    private var mainPane: some View {
        if let work = selectedWork {
            LibraryWorkDetailView(item: work,
                disabled: !recordingManager.canPerformLibraryWork || library.isQuerying || library.error != nil) {
                try await recordingManager.performLibraryWork(work)
                if recordingManager.reprocessingRecoveryReady { library.refresh() }
            }
            .id(work.id)
        } else if let recording = detailRecording {
            TranscriptDetailView(
                recording: recording,
                onDeleted: { handleDeleted(recording.fileURL) }
            )
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
                appState.lastError = nil
                Task { try? await recordingManager.startRecording() }
            },
            onRefresh: reload,
            onRebuildSearchIndex: { library.refresh(rebuild: true) },
            onSettings: { openWindow(id: "settings") }
        ) { statusMenu in
            if liveRecording != nil || processingRecording != nil {
                sidebarSectionHeading("In Progress")
                if let live = liveRecording {
                    LiveSidebarRow(recording: live, isProcessing: false,
                        isSelected: selection == live.fileURL,
                        onTap: { selectRecording(live.fileURL) })
                }
                if let proc = processingRecording {
                    LiveSidebarRow(recording: proc, isProcessing: true,
                        isSelected: selection == proc.fileURL,
                        onTap: { selectRecording(proc.fileURL) })
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
        guard !library.hasMatches,
              liveRecording == nil,
              processingRecording == nil,
              !library.showsInitialLoading,
              library.error == nil else { return nil }
        return emptyDescription
    }

    @ViewBuilder private func smartResults(statusMenu: ViewerSidebarStatusFilterMenu) -> some View {
        switch library.selectedView {
        case .all:
            VStack(alignment: .leading, spacing: 2) {
                sidebarResultsHeading("This week", statusMenu: statusMenu)
                ForEach(thisWeekItems) { row(for: $0) }

                if !earlierItems.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { earlierCollapsed.toggle() }
                    } label: {
                        HStack(spacing: 7) {
                            Text("Earlier")
                                .uiFont(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.secondary.color)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(palette.secondary.color)
                                .rotationEffect(.degrees(earlierCollapsed ? -90 : 0))
                        }
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Earlier recordings")
                    .accessibilityValue(earlierCollapsed ? "Collapsed" : "Expanded")
                    .accessibilityHint("Shows recordings outside this week.")

                    if !earlierCollapsed {
                        ForEach(earlierItems) { row(for: $0) }
                    }
                }
            }
        case .unfinishedActions:
            VStack(alignment: .leading, spacing: 2) {
                sidebarResultsHeading("Unfinished actions", count: filteredItems.count, statusMenu: statusMenu)
                ForEach(filteredItems) { row(for: $0) }
            }
        case .recentlyProcessed:
            VStack(alignment: .leading, spacing: 2) {
                sidebarResultsHeading("Recently processed", count: filteredItems.count, statusMenu: statusMenu)
                // Preserve SQL processing-time ordering for Recently Processed.
                ForEach(filteredItems) { row(for: $0) }
            }
        case .failedJobs, .queuedInterrupted:
            VStack(alignment: .leading, spacing: 2) {
                sidebarResultsHeading(
                    library.selectedView == .failedJobs ? "Failed jobs" : "Queued / interrupted",
                    count: library.workMatches.count
                )
                ForEach(library.workMatches) { sidebarWorkRow($0) }
            }
        case .peopleThisMonth:
            VStack(alignment: .leading, spacing: 2) {
                sidebarResultsHeading("People this month", count: library.peopleGroups.count, statusMenu: statusMenu)
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
                                .uiFont(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(palette.secondary.color)
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(palette.accentText.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func selectRecording(_ url: URL) {
        selectedWork = nil
        selection = url
    }

    private func updateActiveWork() {
        library.updateActiveWork(ids: activeWorkIDs, audioURLs: activeAudioURLs)
    }

    private func row(for item: RecordingBrowserItem) -> some View {
        SidebarRecordingRow(
            item: item,
            isSelected: selection == item.url,
            onTap: { selectRecording(item.url) })
        .contextMenu { ReprocessingMenu(recording: makeRecording(from: item), hasTranscript: item.hasTranscript, presentationStyle: .window) }
    }

    private func sidebarResultsHeading(
        _ title: String,
        count: Int? = nil,
        statusMenu: ViewerSidebarStatusFilterMenu? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .uiFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondary.color)
            if let count {
                Text("\(count)")
                    .uiFont(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.secondary.color)
            }
            Spacer(minLength: 4)
            if let statusMenu { statusMenu }
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .frame(height: 32)
        .accessibilityElement(children: .contain)
    }

    private func sidebarSectionHeading(_ title: String) -> some View {
        Text(title)
            .uiFont(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.secondary.color)
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 4)
    }

    private func sidebarWorkRow(_ item: LibraryWorkItem) -> some View {
        let isSelected = selectedWork?.id == item.id
        return Button {
            selection = nil
            detailRecording = nil
            selectedWork = item
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .uiFont(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? palette.accentText.color : palette.text.color)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.status)
                    Text("·")
                    Text(item.date, style: .date)
                }
                .uiFont(.system(size: 10).monospaced())
                .foregroundStyle(palette.secondary.color)
                if let audio = item.audioURL {
                    Text(audio.deletingLastPathComponent().path)
                        .uiFont(.system(size: 10))
                        .foregroundStyle(palette.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                isSelected ? palette.selected.color : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue("\(item.status), \(item.date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                detailRecording = makeRecording(from: item)
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
        guard appState.pendingLiveTranscriptSelection else { return }
        // Prefer the background processing job's row (the "Live Transcript" button in the
        // processing progress view is the common source); fall back to the capture row.
        if let proc = processingRecording { selection = proc.fileURL }
        else if let live = liveRecording { selection = live.fileURL }
        // The URL may already be selected, so onChange(selection) need not fire.
        // Switch from the published recording to this job's staged object anyway.
        selectedWork = nil
        rebuildDetailRecording()
        appState.pendingLiveTranscriptSelection = false
    }

    private func handleDeleted(_ url: URL) {
        library.refresh()
        if selection == url { selection = nil }
        if detailRecording?.fileURL == url { detailRecording = nil }
    }

    private func makeRecording(from item: RecordingBrowserItem) -> Recording {
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

/// `23 Jun` short date used in the sidebar captions.
private let sidebarDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM"
    return f
}()

/// Selectable recording row with theme-adapted selection and hover states.
struct SidebarRecordingRow: View {
    let item: RecordingBrowserItem
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.viewerPalette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .lineLimit(1)
                caption
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.title)
        .accessibilityValue("\(item.statusText), \(item.date.formatted(date: .abbreviated, time: .shortened)), \(item.formattedDuration)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var caption: some View {
        HStack(spacing: 7) {
            Text(captionText)
            if !item.statusText.isEmpty {
                Text(item.statusText)
            }
        }
        .uiFont(.system(size: 11))
        .foregroundStyle(palette.secondary.color)
    }

    private var captionText: String {
        let date = sidebarDateFormatter.string(from: item.date)
        return item.formattedDuration.isEmpty ? date : "\(date) · \(item.formattedDuration)"
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.selected.color)
        } else if hovering {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.selected.color.opacity(0.55))
        }
    }
}

/// Pinned in-progress row — pulsing red/orange dot plus "Recording…/Processing…".
private struct LiveSidebarRow: View {
    let recording: Recording
    let isProcessing: Bool
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.viewerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pulse = false

    private var statusText: String {
        isProcessing ? "Processing…" : "Recording…"
    }
    private var dotColor: Color {
        isProcessing ? .orange : .red
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.generatedTitle ?? recording.meetingTitleDraft)
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                        .opacity(reduceMotion || pulse ? 1 : 0.4)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                        .accessibilityHidden(true)
                    Text(statusText)
                }
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(palette.selected.color)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(palette.selected.color.opacity(0.55))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { pulse = !reduceMotion }
        .accessibilityLabel(recording.generatedTitle ?? recording.meetingTitleDraft)
        .accessibilityValue(statusText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
