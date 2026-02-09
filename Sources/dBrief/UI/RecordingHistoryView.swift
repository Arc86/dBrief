import SwiftUI

struct RecordingHistoryView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AudioPlayer.self) private var audioPlayer
    @State private var recordings: [HistoryItem] = []

    struct HistoryItem: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let date: Date
        let size: Int64

        var formattedDate: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                Text("\(item.formattedDate) — \(item.formattedSize)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            audioPlayer.currentFileURL == item.url
                ? Color.accentColor.opacity(0.1)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
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
        let folder = appSettings.recordingFolderURL
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        recordings = contents
            .filter { ["m4a", "wav", "mp3", "aac"].contains($0.pathExtension.lowercased()) }
            .compactMap { url -> HistoryItem? in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return HistoryItem(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    date: values?.creationDate ?? Date.distantPast,
                    size: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.date > $1.date }
    }
}
