import SwiftUI
import AppKit

/// Explicit per-recording processing state surfaced in the menu-bar list,
/// replacing the old cryptic "✓ AI". Rendered as an SF Symbol + tinted Label
/// (theme-adaptive, reads natively in Light/Dark) rather than a filled pill.
enum RecordingStatus {
    case analyzed
    case transcribed
    case queued

    var label: String {
        switch self {
        case .analyzed: "Analyzed"
        case .transcribed: "Transcribed"
        case .queued: "Queued"
        }
    }

    var systemImage: String {
        switch self {
        case .analyzed: "checkmark.seal.fill"
        case .transcribed: "waveform"
        case .queued: "clock"
        }
    }

    var tint: Color {
        switch self {
        case .analyzed: .green
        case .transcribed: .secondary
        case .queued: .orange
        }
    }
}

struct RecordingHistoryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(RecordingManager.self) private var recordingManager
    @State private var recordings: [HistoryItem] = []
    /// Tracks the in-flight load so overlapping loads can't resolve out of order.
    @State private var loadTask: Task<Void, Never>?
    @State private var expandedItemId: UUID?
    @State private var hoveredItemId: UUID?
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
        var status: RecordingStatus? {
            if hasInsights { return .analyzed }
            if hasTranscript { return .transcribed }
            if isQueued { return .queued }
            return nil
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
            if let generated = generatedTitle?.trimmingCharacters(in: .whitespaces), !generated.isEmpty {
                return generated
            }
            let parts = name.split(separator: "_", maxSplits: 2)
            guard parts.count == 3 else { return name }
            return String(parts[2]).replacingOccurrences(of: "-", with: " ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Recent Recordings")
                    .font(.headline)
                Spacer()
                Button {
                    openWindow(id: "transcript")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Transcript viewer", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the transcript viewer")

                Button {
                    loadRecordings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Refresh")
            }

            if recordings.isEmpty {
                Text("No recordings found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
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

            // Mini player
            if audioPlayer.currentFileURL != nil {
                Divider()
                miniPlayer
            }
        }
        .onAppear {
            loadRecordings()
        }
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        let isExpanded = expandedItemId == item.id
        return VStack(spacing: 0) {
            // Collapsed row header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedItemId = isExpanded ? nil : item.id
                }
                if !isExpanded { loadSummary(for: item) }
            } label: {
                HStack(spacing: 8) {
                    Button {
                        audioPlayer.togglePlayPause(url: item.url)
                    } label: {
                        Image(systemName: audioPlayer.currentFileURL == item.url && audioPlayer.isPlaying
                            ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Brand.violet2)
                            .frame(width: 30, height: 30)
                            .background(Brand.violetTint, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .onTapGesture {}  // prevent row tap propagation

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                            .font(.callout)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            Text(item.formattedDate)
                            if !item.formattedDuration.isEmpty {
                                Text("·")
                                Text(item.formattedDuration)
                            }
                            if let status = item.status {
                                Text("·")
                                Label(status.label, systemImage: status.systemImage)
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(status.tint)
                                    .accessibilityLabel("Status: \(status.label)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            // Expanded action chips
            if isExpanded {
                FlowLayout(spacing: 6) {
                    if item.hasTranscript {
                        actionChip(
                            title: loadedSummaries[item.id] != nil ? "Copy Summary" : "Copy Transcript",
                            systemImage: "doc.on.doc"
                        ) {
                            let text = loadedSummaries[item.id] ?? ""
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
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

                    if item.hasTranscript {
                        actionChip(title: "Re-run AI", systemImage: "arrow.trianglehead.2.clockwise") {
                            Task {
                                let recording = Recording(
                                    fileURL: item.url,
                                    fileSize: item.size,
                                    meetingTitleDraft: item.name,
                                    finalizedAudioURL: item.url
                                )
                                await recordingManager.retryAIAnalysis(for: recording)
                            }
                        }
                    }

                    if item.hasRichTranscript {
                        actionChip(title: "Transcript", systemImage: "doc.text") {
                            appState.pendingTranscriptSelectionURL = item.url
                            openWindow(id: "transcript")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }

                    actionChip(title: "Delete", systemImage: "trash", destructive: true) {
                        deleteItem(item)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
        }
        .background(rowBackground(for: item, isExpanded: isExpanded))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            if hovering {
                hoveredItemId = item.id
            } else if hoveredItemId == item.id {
                hoveredItemId = nil
            }
        }
    }

    private func rowBackground(for item: HistoryItem, isExpanded: Bool) -> Color {
        if audioPlayer.currentFileURL == item.url || isExpanded {
            return Brand.violet.opacity(0.1)
        }
        if hoveredItemId == item.id {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }

    private func actionChip(title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(destructive ? .red : .primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    @MainActor
    private func loadSummary(for item: HistoryItem) {
        guard loadedSummaries[item.id] == nil else { return }
        Task {
            let base = item.url.deletingPathExtension()
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
        let base = item.url.deletingPathExtension()
        let candidates = [
            item.url,
            base.appendingPathExtension("md"),
            base.appendingPathExtension("transcript.json"),
            base.appendingPathExtension("richtranscript.json"),
            base.appendingPathExtension("insights.json"),
            base.appendingPathExtension("chat.json"),
            base.appendingPathExtension("spokensummary.json"),
            base.appendingPathExtension("spokensummary.m4a"),
            base.appendingPathExtension("json"),
        ]
        for url in candidates {
            try? FileManager.default.removeItem(at: url)
        }
        recordings.removeAll { $0.id == item.id }
        if expandedItemId == item.id { expandedItemId = nil }
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

    private static let segmentSuffix = try! NSRegularExpression(pattern: "_part\\d+$")

    private func loadRecordings() {
        // Enumerate + decode metadata sidecars off the main actor; the current
        // list stays visible until the new one arrives. Runs on menu open and
        // after processing, so it must not block the UI with the library size.
        let folder = appSettings.effectiveRecordingFolderURL
        loadTask?.cancel()
        loadTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.buildHistoryItems(in: folder)
            }.value
            if Task.isCancelled { return }
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
