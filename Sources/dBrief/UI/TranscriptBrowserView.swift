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
    @Environment(\.calmAppearance) private var calm

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
        guard let job = appState.processingJob, job.reprocessingAttemptID == nil else { return nil }
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
        // Native collapsible + resizable sidebar (system component) hosting the
        // redesigned meeting list. The neon ambient lives on the detail side; the
        // sidebar uses the standard vibrant sidebar material (the navigation glass
        // layer). `sidebarOpen` maps to the split view's column visibility so the
        // native sidebar toggle + the persisted open/closed state stay in sync.
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarOpen ? .all : .detailOnly },
            set: { newValue in sidebarOpen = (newValue != .detailOnly) }
        )) {
            sidebar
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 220, ideal: 256, max: 360)
        } detail: {
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { TranscriptDesignTokens.ambientBackground(scheme: colorScheme, calm: calm) }
        }
        .navigationTitle("dBrief")
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            // Refresh + Settings sit at the leading edge, right next to the native
            // sidebar-collapse toggle.
            ToolbarItemGroup(placement: .navigation) {
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .accessibilityLabel("Refresh recordings")

                Menu {
                    Picker("View", selection: viewSelection) {
                        ForEach(LibrarySmartView.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Button("Rebuild Search Index") { library.refresh(rebuild: true) }
                        .disabled(library.isRefreshing)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Library options")
                .accessibilityLabel("Library options")

                Button { openWindow(id: "settings") } label: {
                    Image(systemName: "gearshape")
                }
                .help("Open Settings (⌘,)")
                .accessibilityLabel("Open Settings")
            }
        }
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
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)

            TranscriptLibraryFilters(view: viewSelection, status: $statusFilter,
                                     isLoading: library.showsInitialLoading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if let scope = scopeDescription {
                Text(scope).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let error = library.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption)
                    Button("Retry") { library.refresh() }
                }
                .padding(12)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if liveRecording != nil || processingRecording != nil {
                        sectionLabel("In Progress")
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
                    smartResults
                    if !library.hasMatches && !library.showsInitialLoading && library.error == nil {
                        Text(searchText.isEmpty ? emptyDescription : "No matches for this search.")
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .overlayScrollers()
            }

            recordButton
                .padding(12)
        }
    }

    private var scopeDescription: String? {
        switch library.selectedView {
        case .failedJobs, .queuedInterrupted: "Queued and recovery work from all folders."
        case .recentlyProcessed: "Successfully processed in the last seven days."
        case .peopleThisMonth: "People in this month's recordings in the selected folder."
        case .unfinishedActions: "Open action items in the selected folder."
        case .all: nil
        }
    }

    private var emptyDescription: String {
        switch library.selectedView {
        case .all: "No recordings in this folder."
        case .unfinishedActions: "No unfinished actions."
        case .failedJobs: "No failed jobs."
        case .queuedInterrupted: "No queued or interrupted work."
        case .recentlyProcessed: "No recordings processed in the last seven days."
        case .peopleThisMonth: "No named people in this month's recordings."
        }
    }

    @ViewBuilder private var smartResults: some View {
        if library.selectedView.includesRecoveryWork {
            ForEach(library.workMatches) { item in
                Button {
                    selection = nil
                    detailRecording = nil
                    selectedWork = item
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).lineLimit(2)
                        Text(item.status).font(.caption).foregroundStyle(.secondary)
                        Text(item.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        if let audio = item.audioURL {
                            Text(audio.deletingLastPathComponent().path)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(selectedWork?.id == item.id ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue("\(item.status), \(item.date.formatted(date: .abbreviated, time: .shortened))")
                .accessibilityAddTraits(selectedWork?.id == item.id ? .isSelected : [])
            }
        } else if library.selectedView == .peopleThisMonth {
            ForEach(library.peopleGroups) { group in
                DisclosureGroup {
                    ForEach(group.recordings) { row(for: $0) }
                } label: {
                    Text("\(group.person.name) (\(group.recordings.count))")
                        .font(.headline)
                }
                .padding(.vertical, 6)
            }
        } else if library.selectedView == .all {
            if !thisWeekItems.isEmpty {
                sectionLabel("This week", count: thisWeekItems.count)
                ForEach(thisWeekItems) { row(for: $0) }
            }
            if !earlierItems.isEmpty {
                sectionLabel("Earlier", count: earlierItems.count, collapsed: earlierCollapsed) {
                    withAnimation(.easeInOut(duration: 0.18)) { earlierCollapsed.toggle() }
                }
                if !earlierCollapsed { ForEach(earlierItems) { row(for: $0) } }
            }
        } else {
            // Preserve SQL processing-time ordering for Recently Processed.
            ForEach(filteredItems) { row(for: $0) }
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
        .contextMenu { ReprocessingMenu(recording: makeRecording(from: item), hasTranscript: item.hasTranscript) }
    }

    /// Section header for the meeting list. Passing `collapsed`/`onToggle` makes it
    /// a tappable, collapsible header with a chevron (used by "Earlier").
    private func sectionLabel(_ text: String,
                              count: Int? = nil,
                              collapsed: Bool? = nil,
                              onToggle: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: 7) {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold).monospaced())
                .tracking(1.2)
                .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme).opacity(0.55))
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(TranscriptDesignTokens.chipFill(scheme: colorScheme)))
            }
            Spacer(minLength: 4)
            if let collapsed {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        return Group {
            if let onToggle {
                Button(action: onToggle) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
            TextField("Search recordings and transcripts", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(TranscriptDesignTokens.chipFill(scheme: colorScheme))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(TranscriptDesignTokens.chipBorder(scheme: colorScheme), lineWidth: 1))
        }
    }

    private var recordButton: some View {
        Button {
            appState.lastError = nil
            Task { try? await recordingManager.startRecording() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Record meeting")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(TranscriptDesignTokens.brandFill(calm: calm), in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: calm ? .clear : Color(hex: "8b4dff").opacity(0.5), radius: calm ? 0 : 14, x: 0, y: calm ? 0 : 8)
        }
        .buttonStyle(.plain)
        .disabled(!appState.isIdle)
        .opacity(appState.isIdle ? 1 : 0.5)
        .help(appState.isIdle ? "Start a new recording" : "Already recording")
    }

    // MARK: - Helpers

    private func reload() {
        guard recordingManager.reprocessingRecoveryReady else { return }
        library.open(appSettings.effectiveRecordingFolderURL, configuredQueueFolders: queueDiscoveryFolders)
    }

    private func rebuildDetailRecording() {
        // Selecting a pinned in-progress entry shows that recording object directly.
        if let live = liveRecording, selection == live.fileURL {
            if detailRecording !== live { detailRecording = live }
            return
        }
        if let proc = processingRecording, selection == proc.fileURL {
            if detailRecording !== proc { detailRecording = proc }
            return
        }
        if let item = selectedItem {
            if detailRecording?.fileURL != item.url {
                detailRecording = makeRecording(from: item)
            }
        } else {
            detailRecording = nil
        }
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

private let sidebarStatusGreen = Color(hex: "28c840")

/// Selectable meeting row matching the redesign: title + mono caption, a gradient
/// fill + coral→violet bar when selected, a hover tint otherwise.
private struct SidebarRecordingRow: View {
    let item: RecordingBrowserItem
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.calmAppearance) private var calm
    @State private var hovering = false

    private var doneColor: Color {
        scheme == .dark ? Color(hex: "54e6ff") : Color.secondary
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected
                        ? TranscriptDesignTokens.bodyText(scheme: scheme)
                        : TranscriptDesignTokens.bodyText(scheme: scheme).opacity(0.85))
                    .lineLimit(1)
                caption
            }
            .padding(.vertical, 10)
            .padding(.leading, isSelected ? 14 : 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { background }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(TranscriptDesignTokens.accentBarFill(calm: calm))
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }
            }
            .contentShape(Rectangle())
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
            if item.statusText == "Done" {
                if isSelected {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 3, height: 3)
                    Text("Done").foregroundStyle(doneColor)
                } else {
                    Circle().fill(sidebarStatusGreen).frame(width: 5, height: 5)
                }
            } else if !item.statusText.isEmpty {
                Text(item.statusText).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11).monospaced())
        .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: scheme))
    }

    private var captionText: String {
        let date = sidebarDateFormatter.string(from: item.date)
        return item.formattedDuration.isEmpty ? date : "\(date) · \(item.formattedDuration)"
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10)
                .fill(TranscriptDesignTokens.sidebarActiveFill(scheme: scheme, calm: calm))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(TranscriptDesignTokens.sidebarActiveBorder(scheme: scheme), lineWidth: 1))
        } else if hovering {
            RoundedRectangle(cornerRadius: 10)
                .fill(TranscriptDesignTokens.sidebarHoverFill(scheme: scheme))
        }
    }
}

/// Pinned in-progress row — pulsing red/orange dot plus "Recording…/Processing…".
private struct LiveSidebarRow: View {
    let recording: Recording
    let isProcessing: Bool
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.calmAppearance) private var calm
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: scheme))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                        .opacity(reduceMotion || pulse ? 1 : 0.4)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                        .accessibilityHidden(true)
                    Text(statusText)
                }
                .font(.system(size: 11).monospaced())
                .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: scheme))
            }
            .padding(.vertical, 10)
            .padding(.leading, isSelected ? 14 : 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TranscriptDesignTokens.sidebarActiveFill(scheme: scheme, calm: calm))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(TranscriptDesignTokens.sidebarActiveBorder(scheme: scheme), lineWidth: 1))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TranscriptDesignTokens.sidebarHoverFill(scheme: scheme))
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(TranscriptDesignTokens.accentBarFill(calm: calm))
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { pulse = !reduceMotion }
        .accessibilityLabel(recording.generatedTitle ?? recording.meetingTitleDraft)
        .accessibilityValue(statusText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
