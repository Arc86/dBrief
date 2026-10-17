import SwiftUI
import AppKit

/// Explicit per-recording processing state surfaced in the menu-bar list,
/// replacing the old cryptic "✓ AI". Rendered as an SF Symbol + tinted Label
/// (theme-adaptive, reads natively in Light/Dark) rather than a filled pill.
enum RecordingStatus {
    case recorded
    case analyzed
    case transcribed
    case queued
    case processing
    case reprocessPending
    case needsAttention

    /// Running and saved work win over what the sidecar files say.
    static func resolve(ownership: RecordingOwnership, saved: RecordingStatus) -> RecordingStatus {
        if ownership.isActiveJob || ownership.isCaptureOrReview { return .processing }
        if ownership.pendingAttemptID != nil { return .reprocessPending }
        if ownership.queueMarkerID != nil { return .queued }
        if ownership.unfinishedJobID != nil { return .needsAttention }
        return saved
    }

    var label: String {
        switch self {
        case .recorded: "Not processed"
        case .analyzed: "Analyzed"
        case .transcribed: "Transcribed"
        case .queued: "Queued"
        case .processing: "Processing"
        case .reprocessPending: "Reprocess pending"
        case .needsAttention: "Needs attention"
        }
    }

    /// Only states worth calling out get an icon and a tone; the rest read as
    /// a plain continuation of the metadata line.
    var systemImage: String? {
        switch self {
        case .analyzed: "checkmark.circle"
        case .queued: "clock"
        case .processing: "waveform"
        case .reprocessPending: "clock.arrow.circlepath"
        case .needsAttention: "exclamationmark.triangle"
        case .recorded, .transcribed: nil
        }
    }

    var tone: MenuPanelStatus.Tone? {
        switch self {
        case .analyzed: .success
        case .queued, .reprocessPending, .needsAttention: .warning
        case .processing: .accent
        case .recorded, .transcribed: nil
        }
    }
}

struct RecordingHistoryView: View {
    @Binding var expanded: Bool
    let recordingActionPresentationStyle: ReprocessingMenuPresentationStyle = .window
    @Environment(\.openWindow) private var openWindow
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var panelStatus
    @State private var recordings: [HistoryItem] = []
    /// Tracks the in-flight load so overlapping loads can't resolve out of order.
    @State private var loadTask: Task<Void, Never>?
    @State private var expandedItemId: URL?
    @State private var loadedSummaries: [URL: String] = [:]
    /// The row whose notes were just copied, for the "Copied" confirmation.
    @State private var copiedItem: URL?

    struct HistoryItem: Identifiable, Equatable, Sendable {
        /// Keyed by the audio file so a reload keeps each row's identity; a random
        /// id made every reload replace every row (the stale-list flash).
        var id: URL { url }
        let url: URL
        let name: String
        let date: Date
        let size: Int64
        let duration: TimeInterval
        let profileName: String?
        let hasTranscript: Bool
        let hasRichTranscript: Bool
        let hasInsights: Bool
        let isQueued: Bool
        /// AI-generated title persisted to the metadata sidecar after
        /// post-processing; preferred over the filename-derived name. See #71.
        var generatedTitle: String? = nil
        /// Resolved off-main while building the list, never during rendering.
        var markdownURL: URL? = nil

        /// Derived processing state for the row's status badge. AI analysis is
        /// signalled by the `<base>.insights.json` sidecar (written only when a
        /// summary exists); a pending `<base>.queue.json` means awaiting processing.
        var status: RecordingStatus {
            if isQueued { return .queued }
            if hasInsights { return .analyzed }
            if hasTranscript { return .transcribed }
            return .recorded
        }

        /// Same text as the library sidebar, following the system's 12/24-hour setting.
        var formattedDate: String { LibraryRowFormat.date(date) }

        var formattedDuration: String { RecordingListPresentation.duration(duration) }

        var displayName: String {
            RecordingListPresentation.title(filenameStem: name, generatedTitle: generatedTitle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordingListSectionHeader(title: "Recent recordings", count: nil, expanded: $expanded) {
                RecordingListIconButton(title: "Refresh recent recordings", systemImage: "arrow.clockwise") {
                    loadRecordings()
                }
            }

            if expanded {
                if !recordingManager.reprocessingRecoveryReady {
                    ReprocessingRecoveryView().frame(height: 170)
                } else if recordings.isEmpty {
                    RecordingListEmptyState(title: "No recordings found", message: "Your recent recordings will appear here.", systemImage: "waveform")
                } else {
                    // A short list that grows the panel instead of a scroll box inside
                    // the panel's own scroll view; everything else lives in the library.
                    historyRows
                    if recordings.count > Self.visibleCount {
                        Button {
                            MenuBarPanel.open("transcript", with: openWindow)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Show all in library")
                                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 22, fontSize: 11))
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }

            // Mini player
            if audioPlayer.currentFileURL != nil {
                MenuPanelHairline()
                miniPlayer
            }
        }
        .onAppear { loadRecordings() }
        .onChange(of: recordingManager.reprocessingRecoveryReady) { _, ready in
            if ready { loadRecordings() }
            else { loadTask?.cancel(); loadedSummaries = [:]; recordings = [] }
        }
        .onChange(of: appState.queuedCount) { _, _ in loadRecordings() }
        .onChange(of: recordingManager.reprocessingResultsRevision) { _, _ in
            loadedSummaries = [:]
            loadRecordings()
        }
    }

    private var historyRows: some View {
        VStack(spacing: 0) {
            let visible = recordings.prefix(Self.visibleCount)
            ForEach(visible) { item in
                historyRow(item)
                    .overlay(alignment: .bottom) {
                        if item.id != visible.last?.id { MenuPanelHairline() }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        let isExpanded = expandedItemId == item.id
        return RecordingListRow(
            title: item.displayName, expanded: isExpanded,
            selected: audioPlayer.currentFileURL == item.url,
            toggle: {
                expandedItemId = isExpanded ? nil : item.id
                if !isExpanded { loadSummary(for: item) }
            }
        ) {
            RecordingListPlayButton(
                isPlaying: audioPlayer.currentFileURL == item.url && audioPlayer.isPlaying,
                title: item.displayName
            ) {
                audioPlayer.togglePlayPause(url: item.url)
            }
        } metadata: {
            HStack(spacing: 4) {
                Text(item.formattedDate + (item.formattedDuration.isEmpty ? "" : " · \(item.formattedDuration)"))
                    .lineLimit(1)
                let status = RecordingStatus.resolve(ownership: recordingManager.liveOwnership(for: item.url),
                                                     saved: item.status)
                RecordingListStatus(
                    title: status.label, systemImage: status.systemImage,
                    tint: status.tone?.color(palette: palette, status: panelStatus))
            }
        } actions: {
            // Fixed 3 × 2 grid: unavailable actions stay in place, disabled, so the
            // grid never reflows between recordings.
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    actionTile(title: copiedItem == item.id ? "Copied" : (item.hasInsights ? "Copy notes" : "Copy transcript"),
                               systemImage: copiedItem == item.id ? "checkmark" : "doc.on.doc") {
                        Task {
                            guard let text = await RecordingNotesText.load(for: item.url),
                                  await RecordingClipboard.copy(text, from: item.url) else { return }
                            copiedItem = item.id
                            try? await Task.sleep(for: .seconds(2))
                            if copiedItem == item.id { copiedItem = nil }
                        }
                    }
                    .disabled(!item.hasTranscript)
                    .help(item.hasInsights ? "Copy the summary and action items" : "Copy the transcript (no summary yet)")

                    actionTile(title: "Show in Finder", systemImage: "folder") {
                        MenuBarPanel.reveal(item.url)
                    }

                    ReprocessingMenu(recording: recordingModel(item), hasTranscript: item.hasTranscript,
                        presentationStyle: recordingActionPresentationStyle,
                        stacksLabel: true)
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(MenuPanelButtonStyle(kind: .tile, height: 42, fontSize: 11))
                }
                GridRow {
                    // The viewer can also transcribe or rebuild a recording without a transcript.
                    actionTile(title: "Open", systemImage: "doc.text") { openInLibrary(item) }
                    .help("Open in the recording library")

                    actionTile(title: "Integrations", systemImage: "paperplane") {
                        Task { await recordingManager.reviewIntegrationDeliveries(for: item.url) }
                    }
                    .disabled(appState.processingJob != nil || recordingManager.reviewingIntegrationDeliveries)
                    .help(appState.processingJob != nil
                        ? "Wait for processing to finish to review integration deliveries"
                        : "Review delivery status and retry an individual integration")

                    actionTile(title: "Delete", systemImage: "trash", destructive: true) {
                        deleteItem(item)
                    }
                    .recordingBlock(recordingManager.eligibility(for: item.url, .delete), help: "Delete this recording")
                }
            }
        }
        // The same actions as the library row, for right-click and keyboard users.
        .contextMenu {
            RecordingContextMenu(recording: recordingModel(item), hasTranscript: item.hasTranscript,
                                 open: { openInLibrary(item) },
                                 onDeleted: { removeDeleted(item) })
        }
    }

    private func actionTile(title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        RecordingListAction(title: title, systemImage: systemImage, destructive: destructive, style: .tile, action: action)
    }

    @MainActor
    private func loadSummary(for item: HistoryItem) {
        guard recordingManager.reprocessingRecoveryReady else { return }
        guard loadedSummaries[item.id] == nil else { return }
        let revision = recordingManager.reprocessingResultsRevision
        Task {
            guard recordingManager.reprocessingRecoveryReady,
                  revision == recordingManager.reprocessingResultsRevision else { return }
            let base = item.url.deletingPathExtension()
            if let data = try? Data(contentsOf: base.appendingPathExtension("insights.json")),
               let insights = try? JSONDecoder().decode(RecordingInsights.self, from: data),
               !insights.summary.isEmpty {
                loadedSummaries[item.id] = insights.summary
                return
            }
            if let mdURL = item.markdownURL,
               let content = try? String(contentsOf: mdURL, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n")
                var inSummary = false
                var summaryLines: [String] = []
                for line in lines {
                    if line.hasPrefix("## Summary") { inSummary = true; continue }
                    if inSummary {
                        if line.hasPrefix("## ") { break }
                        summaryLines.append(line)
                    }
                }
                let summary = summaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty { loadedSummaries[item.id] = summary; return }
            }
            let transcriptURL = base.appendingPathExtension("transcript.json")
            if let data = try? Data(contentsOf: transcriptURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                loadedSummaries[item.id] = text
            }
        }
    }

    private func deleteItem(_ item: HistoryItem) {
        Task {
            if await RecordingDeletion.confirmAndDelete(item.url, title: item.displayName,
                                                        manager: recordingManager, appState: appState) {
                removeDeleted(item)
            } else {
                loadRecordings()
            }
        }
    }

    private func removeDeleted(_ item: HistoryItem) {
        recordings.removeAll { $0.id == item.id }
        if expandedItemId == item.id { expandedItemId = nil }
    }

    private func recordingModel(_ item: HistoryItem) -> Recording {
        Recording(fileURL: item.url, fileSize: item.size, meetingTitleDraft: item.name, finalizedAudioURL: item.url)
    }

    private func openInLibrary(_ item: HistoryItem) {
        appState.pendingTranscriptSelectionURL = item.url
        MenuBarPanel.open("transcript", with: openWindow)
    }

    private var miniPlayer: some View {
        HStack(spacing: 8) {
            Button {
                if let url = audioPlayer.currentFileURL {
                    audioPlayer.togglePlayPause(url: url)
                }
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(palette.primary.color)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

            Text(audioPlayer.formattedCurrentTime)
                .uiFont(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.secondary.color)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(palette.divider.color)
                    Rectangle()
                        .fill(palette.primary.color)
                        .frame(width: audioPlayer.duration > 0
                            ? geo.size.width * (audioPlayer.currentTime / audioPlayer.duration)
                            : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            audioPlayer.seek(to: audioPlayer.duration * fraction)
                        }
                )
            }
            .frame(height: 6)

            Text(audioPlayer.formattedDuration)
                .uiFont(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.secondary.color)

            Button {
                audioPlayer.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 22))
            .accessibilityLabel("Stop playback")
        }
    }

    /// Rows shown in the panel; the library holds the rest.
    static let visibleCount = 5

    nonisolated private static let segmentSuffix = try! NSRegularExpression(pattern: "_part\\d+$")

    private func loadRecordings() {
        guard recordingManager.reprocessingRecoveryReady else { return }
        let revision = recordingManager.reprocessingResultsRevision
        // Enumerate + decode metadata sidecars off the main actor; the current
        // list stays visible until the new one arrives. Runs on menu open and
        // after processing, so it must not block the UI with the library size.
        let folder = appSettings.effectiveRecordingFolderURL
        loadTask?.cancel()
        loadTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.buildHistoryItems(in: folder)
            }.value
            guard !Task.isCancelled, recordingManager.reprocessingRecoveryReady,
                  revision == recordingManager.reprocessingResultsRevision else { return }
            if recordings != loaded { recordings = loaded }
            let reconciled = Self.reconcile(loaded: loaded, summaries: loadedSummaries, expanded: expandedItemId)
            if reconciled.summaries.count != loadedSummaries.count { loadedSummaries = reconciled.summaries }
            if reconciled.expanded != expandedItemId { expandedItemId = reconciled.expanded }
        }
    }

    /// Drops cached summaries and expansion for recordings no longer listed, so
    /// state can't accumulate across reloads.
    static func reconcile(loaded: [HistoryItem], summaries: [URL: String], expanded: URL?)
        -> (summaries: [URL: String], expanded: URL?) {
        let present = Set(loaded.map(\.id))
        return (summaries.filter { present.contains($0.key) },
                expanded.flatMap { present.contains($0) ? $0 : nil })
    }

    nonisolated private static func buildHistoryItems(in folder: URL) -> [HistoryItem] {
        let all = RecordingDiscovery.discover(in: folder).filter { entry in
            let stem = entry.url.deletingPathExtension().lastPathComponent
            let range = NSRange(stem.startIndex..., in: stem)
            return Self.segmentSuffix.firstMatch(in: stem, range: range) == nil
        }
        return Array(all.prefix(20)).map { entry in
            let base = entry.url.deletingPathExtension()
            let transcriptURL = base.appendingPathExtension("transcript.json")
            let hasTranscript = FileManager.default.fileExists(atPath: transcriptURL.path)
            let richTranscriptURL = base.appendingPathExtension("richtranscript.json")
            let hasRichTranscript = FileManager.default.fileExists(atPath: richTranscriptURL.path)
            let insightsURL = base.appendingPathExtension("insights.json")
            let hasInsights = FileManager.default.fileExists(atPath: insightsURL.path)
            let queueURL = base.appendingPathExtension("queue.json")
            let isQueued = FileManager.default.fileExists(atPath: queueURL.path)

            var duration: TimeInterval = 0
            var generatedTitle: String?
            let metaURL = base.appendingPathExtension("json")
            if let data = try? Data(contentsOf: metaURL),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Key must match RecordingMetadataPayload's encoded field name.
                if let d = meta["durationSeconds"] as? TimeInterval {
                    duration = d
                }
                generatedTitle = meta["generatedTitle"] as? String
            }

            let markdownCandidate = base.appendingPathExtension("md")
            let markdownURL = FileManager.default.fileExists(atPath: markdownCandidate.path) ? markdownCandidate : nil

            return HistoryItem(
                url: entry.url,
                name: base.lastPathComponent,
                date: entry.createdAt,
                size: entry.size,
                duration: duration,
                profileName: nil,
                hasTranscript: hasTranscript,
                hasRichTranscript: hasRichTranscript,
                hasInsights: hasInsights,
                isQueued: isQueued,
                generatedTitle: generatedTitle,
                markdownURL: markdownURL
            )
        }
    }
}
