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

    var label: String {
        switch self {
        case .recorded: "Recorded"
        case .analyzed: "Analyzed"
        case .transcribed: "Transcribed"
        case .queued: "Queued"
        }
    }

    var systemImage: String {
        switch self {
        case .recorded: "mic"
        case .analyzed: "checkmark.seal.fill"
        case .transcribed: "waveform"
        case .queued: "clock"
        }
    }

    var tint: Color {
        switch self {
        case .recorded: .secondary
        case .analyzed: .green
        case .transcribed: .secondary
        case .queued: .orange
        }
    }
}

struct RecordingHistoryView: View {
    @Binding var expanded: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(RecordingManager.self) private var recordingManager
    @State private var recordings: [HistoryItem] = []
    /// Tracks the in-flight load so overlapping loads can't resolve out of order.
    @State private var loadTask: Task<Void, Never>?
    @State private var expandedItemId: UUID?
    @State private var loadedSummaries: [UUID: String] = [:]

    struct HistoryItem: Identifiable, Sendable {
        let id = UUID()
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

        /// Derived processing state for the row's status badge. AI analysis is
        /// signalled by the `<base>.insights.json` sidecar (written only when a
        /// summary exists); a pending `<base>.queue.json` means awaiting processing.
        var status: RecordingStatus {
            if isQueued { return .queued }
            if hasInsights { return .analyzed }
            if hasTranscript { return .transcribed }
            return .recorded
        }

        var formattedDate: String {
            let cal = Calendar.current
            let now = Date.now
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            let timeStr = timeFormatter.string(from: date)

            if cal.isDateInToday(date) {
                return "Today \(timeStr)"
            } else if cal.isDateInYesterday(date) {
                return "Yesterday \(timeStr)"
            } else if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 {
                let dayFormatter = DateFormatter()
                dayFormatter.dateFormat = "EEE"
                return "\(dayFormatter.string(from: date)) \(timeStr)"
            } else {
                let shortFormatter = DateFormatter()
                let year = cal.component(.year, from: date)
                let currentYear = cal.component(.year, from: now)
                shortFormatter.dateFormat = year == currentYear ? "MMM d" : "MMM d, yyyy"
                return shortFormatter.string(from: date)
            }
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }

        var formattedDuration: String {
            guard duration > 0 else { return "" }
            let total = Int(duration)
            let minutes = total / 60
            let seconds = total % 60
            return String(format: "%d:%02d", minutes, seconds)
        }

        var markdownURL: URL? {
            let candidate = url.deletingPathExtension().appendingPathExtension("md")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }

        var displayName: String {
            RecordingListPresentation.title(filenameStem: name, generatedTitle: generatedTitle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordingListSectionHeader(title: "Recent Recordings",
                subtitle: recordings.isEmpty ? "No recordings yet" : "\(recordings.count) recent", expanded: $expanded) {
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
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(recordings) { item in
                                historyRow(item)
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }

            // Mini player
            if audioPlayer.currentFileURL != nil {
                Divider()
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
            Button {
                audioPlayer.togglePlayPause(url: item.url)
            } label: {
                Image(
                    systemName: audioPlayer.currentFileURL == item.url && audioPlayer.isPlaying
                        ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Brand.violet2)
                .frame(width: 30, height: 30)
                .background(Brand.violetTint, in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                "\(audioPlayer.currentFileURL == item.url && audioPlayer.isPlaying ? "Pause" : "Play") \(item.displayName)"
            )
            .help("Play or pause recording")
        } metadata: {
            HStack(spacing: 4) {
                Text(item.formattedDate + (item.formattedDuration.isEmpty ? "" : " · \(item.formattedDuration)"))
                    .lineLimit(1)
                RecordingListStatus(
                    title: item.status.label, systemImage: item.status.systemImage, tint: item.status.tint)
            }
        } actions: {
            FlowLayout(spacing: 6) {
                if item.hasTranscript {
                    actionChip(
                        title: loadedSummaries[item.id] != nil ? "Copy Summary" : "Copy Transcript",
                        systemImage: "doc.on.doc"
                    ) {
                        let text = loadedSummaries[item.id] ?? ""
                        Task { _ = await RecordingClipboard.copy(text, from: item.url) }
                    }
                }

                if let mdURL = item.markdownURL {
                    actionChip(title: "Open File", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(mdURL)
                    }
                } else {
                    actionChip(title: "Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
                    }
                }

                ReprocessingMenu(recording: Recording(
                    fileURL: item.url, fileSize: item.size,
                    meetingTitleDraft: item.name, finalizedAudioURL: item.url
                ), hasTranscript: item.hasTranscript)
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.caption2)
                .foregroundStyle(.primary)
                .fixedSize()

                if item.hasRichTranscript {
                    actionChip(title: "Transcript", systemImage: "doc.text") {
                        appState.pendingTranscriptSelectionURL = item.url
                        openWindow(id: "transcript")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }

                actionChip(title: "Integrations", systemImage: "paperplane") {
                    Task { await recordingManager.reviewIntegrationDeliveries(for: item.url) }
                }
                .disabled(appState.processingJob != nil || recordingManager.reviewingIntegrationDeliveries)
                .help("Review delivery status and retry an individual integration")

                actionChip(title: "Delete", systemImage: "trash", destructive: true) {
                    deleteItem(item)
                }
                .disabled(recordingManager.isReprocessing(item.url))
            }
        }
    }

    private func actionChip(title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        RecordingListAction(title: title, systemImage: systemImage, destructive: destructive, action: action)
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(item.displayName)?"
        alert.informativeText = "This permanently deletes the recording, its local sidecars, queued work, and saved recovery content. Separately exported Markdown and content already sent to integrations are kept."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Recording")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task {
            do {
                try await recordingManager.deleteRecording(item.url)
                recordings.removeAll { $0.id == item.id }
                if expandedItemId == item.id { expandedItemId = nil }
            } catch {
                appState.lastError = "Deletion could not finish. Some files may remain; wait for processing to finish and check storage before retrying."
                loadRecordings()
            }
        }
    }

    private var miniPlayer: some View {
        HStack(spacing: 8) {
            Button {
                if let url = audioPlayer.currentFileURL {
                    audioPlayer.togglePlayPause(url: url)
                }
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)

            Text(audioPlayer.formattedCurrentTime)
                .font(.caption.monospacedDigit())

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                    Rectangle()
                        .fill(.tint)
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
                .font(.caption.monospacedDigit())

            Button {
                audioPlayer.stop()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
    }

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
            recordings = loaded
        }
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
                generatedTitle: generatedTitle
            )
        }
    }
}
