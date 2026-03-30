import SwiftUI
import AppKit

struct RecordingHistoryView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(RecordingManager.self) private var recordingManager
    @State private var recordings: [HistoryItem] = []
    @State private var expandedItemId: UUID?
    @State private var loadedSummaries: [UUID: String] = [:]

    struct HistoryItem: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let date: Date
        let size: Int64
        let duration: TimeInterval
        let profileName: String?
        let hasTranscript: Bool

        var formattedDate: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Recordings")
                    .font(.headline)
                Spacer()
                Button {
                    loadRecordings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
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
                .frame(maxHeight: 200)
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
                            ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .onTapGesture {}  // prevent row tap propagation

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.callout)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            Text(item.formattedDate)
                            if !item.formattedDuration.isEmpty {
                                Text("·")
                                Text(item.formattedDuration)
                            }
                            if item.hasTranscript {
                                Text("·")
                                Text("✓ AI").foregroundStyle(.green)
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
                HStack(spacing: 6) {
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

                    actionChip(title: "Delete", systemImage: "trash", destructive: true) {
                        deleteItem(item)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
        }
        .background(
            (audioPlayer.currentFileURL == item.url || isExpanded)
                ? Color.accentColor.opacity(0.07)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                        .fill(.blue)
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

    private func loadRecordings() {
        let folder = appSettings.effectiveRecordingFolderURL
        let all = RecordingDiscovery.discover(in: folder)
        recordings = Array(all.prefix(20)).map { entry in
            let base = entry.url.deletingPathExtension()
            let transcriptURL = base.appendingPathExtension("transcript.json")
            let hasTranscript = FileManager.default.fileExists(atPath: transcriptURL.path)

            var duration: TimeInterval = 0
            let metaURL = base.appendingPathExtension("json")
            if let data = try? Data(contentsOf: metaURL),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = meta["duration"] as? TimeInterval {
                duration = d
            }

            return HistoryItem(
                url: entry.url,
                name: base.lastPathComponent,
                date: entry.createdAt,
                size: entry.size,
                duration: duration,
                profileName: nil,
                hasTranscript: hasTranscript
            )
        }
    }
}
