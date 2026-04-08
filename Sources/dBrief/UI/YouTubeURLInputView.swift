import SwiftUI

/// Inline panel shown in the menu bar for transcribing a YouTube (or any
/// yt-dlp-supported) URL.  Manages its own loading/error state so it stays
/// self-contained and doesn't pollute AppState.
struct YouTubeURLInputView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager

    @Binding var isVisible: Bool

    @State private var urlText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .disabled(isLoading)
            }

            HStack(spacing: 6) {
                TextField("https://youtube.com/watch?v=...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoading)
                    .onSubmit { submit() }

                Button {
                    submit()
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
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }

            if isLoading {
                Label("Downloading audio…", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if YouTubeDownloadService.findYtDlp() == nil {
                Text("yt-dlp not found. Install with: brew install yt-dlp")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func submit() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                try await recordingManager.loadYouTubeAudio(from: url)
                isVisible = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
