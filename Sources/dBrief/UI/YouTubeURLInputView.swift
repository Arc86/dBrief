import SwiftUI

/// Inline panel shown in the menu bar for transcribing a YouTube (or any
/// yt-dlp-supported) URL. Manages its own loading/error state so it stays
/// self-contained and doesn't pollute AppState.
struct YouTubeURLInputView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager

    @Binding var isVisible: Bool

    // URL entry state
    @State private var urlText = ""
    @State private var isLoading = false
    @State private var loadError: String?

    // yt-dlp availability / download state
    @State private var ytDlpAvailable = false
    @State private var isDownloadingYtDlp = false
    @State private var ytDlpDownloadProgress: Double = 0
    @State private var ytDlpDownloadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(.red)
                Text("YouTube / Video URL")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading || isDownloadingYtDlp)
            }

            // URL input row (only enabled when yt-dlp is ready)
            HStack(spacing: 6) {
                TextField("https://youtube.com/watch?v=…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoading || isDownloadingYtDlp || !ytDlpAvailable)
                    .onSubmit { submitURL() }

                Button {
                    submitURL()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 40)
                    } else {
                        Text("Go")
                            .frame(width: 40)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    !ytDlpAvailable
                    || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isLoading
                    || isDownloadingYtDlp
                )
            }

            if isLoading {
                Label("Downloading audio…", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // yt-dlp availability section
            if !ytDlpAvailable {
                Divider()
                ytDlpSection
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            ytDlpAvailable = YouTubeDownloadService.findYtDlp() != nil
        }
    }

    // MARK: - yt-dlp unavailable section

    @ViewBuilder
    private var ytDlpSection: some View {
        if isDownloadingYtDlp {
            VStack(alignment: .leading, spacing: 4) {
                Label("Downloading yt-dlp…", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                ProgressView(value: ytDlpDownloadProgress)
                    .progressViewStyle(.linear)
                if ytDlpDownloadProgress > 0 {
                    Text("\(Int(ytDlpDownloadProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("yt-dlp not found", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)

                if let error = ytDlpDownloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        downloadYtDlp()
                    } label: {
                        Label(
                            ytDlpDownloadError == nil ? "Download yt-dlp (~15 MB)" : "Retry Download",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(ytDlpDownloadError == nil ? .accentColor : .orange)
                }

                Text("Or install manually: brew install yt-dlp")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func submitURL() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, ytDlpAvailable else { return }
        isLoading = true
        loadError = nil
        Task {
            defer { isLoading = false }
            do {
                try await recordingManager.loadYouTubeAudio(from: url)
                isVisible = false
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func downloadYtDlp() {
        isDownloadingYtDlp = true
        ytDlpDownloadError = nil
        ytDlpDownloadProgress = 0
        Task {
            do {
                for try await progress in YouTubeDownloadService.downloadYtDlp() {
                    ytDlpDownloadProgress = progress
                }
                ytDlpAvailable = true
                // Auto-submit if the user already typed a URL
                if !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submitURL()
                }
            } catch {
                ytDlpDownloadError = error.localizedDescription
            }
            isDownloadingYtDlp = false
        }
    }
}
