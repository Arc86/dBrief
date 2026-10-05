import SwiftUI

/// Inline panel shown in the menu bar for transcribing a YouTube (or any
/// yt-dlp-supported) URL. Manages its own loading/error state so it stays
/// self-contained and doesn't pollute AppState.
struct YouTubeURLInputView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

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
    @State private var ytDlpUpdateStatus: YouTubeDownloadService.YtDlpUpdateStatus?
    @State private var isCheckingYtDlpUpdate = false
    @State private var ytDlpUpdateCheckError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuPanelHairline()
                .padding(.bottom, 4)
            // Header
            HStack {
                Text("YouTube / Video URL")
                    .uiFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Spacer()
                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 22))
                .accessibilityLabel("Close URL input")
                .disabled(isLoading || isDownloadingYtDlp)
            }

            // URL input row (only enabled when yt-dlp is ready)
            HStack(spacing: 8) {
                TextField("Video URL", text: $urlText,
                          prompt: Text("https://youtube.com/watch?v=…").foregroundStyle(palette.secondary.color))
                    .textFieldStyle(.plain)
                    .uiFont(.system(size: 13))
                    .foregroundStyle(palette.heading.color)
                    .padding(.horizontal, 10)
                    .frame(height: 33)
                    .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.divider.color, lineWidth: 1))
                    .disabled(isLoading || isDownloadingYtDlp || !ytDlpAvailable)
                    .onSubmit { submitURL() }

                Button {
                    submitURL()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(palette.onPrimary.color)
                    } else {
                        Text("Go")
                    }
                }
                .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 33, fontSize: 13))
                .frame(width: 52)
                .disabled(
                    !ytDlpAvailable
                    || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isLoading
                    || isDownloadingYtDlp
                )
            }

            if isLoading {
                Label("Downloading audio…", systemImage: "arrow.down.circle")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
            }

            if let error = loadError {
                Text(error)
                    .uiFont(.system(size: 11))
                    .foregroundStyle(status.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ytDlpSection
        }
        .onAppear {
            ytDlpAvailable = YouTubeDownloadService.findYtDlp() != nil
        }
        .task(id: ytDlpAvailable) {
            if ytDlpAvailable { await checkYtDlpUpdate() }
        }
    }

    // MARK: - yt-dlp status

    @ViewBuilder
    private var ytDlpSection: some View {
        if isDownloadingYtDlp {
            VStack(alignment: .leading, spacing: 4) {
                Label(ytDlpAvailable ? "Updating yt-dlp…" : "Downloading yt-dlp…", systemImage: "arrow.down.circle")
                    .uiFont(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.heading.color)
                ProgressView(value: ytDlpDownloadProgress)
                    .progressViewStyle(.linear)
                if ytDlpDownloadProgress > 0 {
                    Text("\(Int(ytDlpDownloadProgress * 100))%")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                }
            }
        } else if !ytDlpAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Label("yt-dlp not found", systemImage: "exclamationmark.triangle")
                    .uiFont(.system(size: 11, weight: .medium))
                    .foregroundStyle(status.warning.color)

                if let error = ytDlpDownloadError {
                    Text(error)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(status.danger.color)
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
                    .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 30, fontSize: 12, fillsWidth: false))
                }

                Text("Or install manually: brew install yt-dlp")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if isCheckingYtDlpUpdate {
                    Label("Checking yt-dlp for updates…", systemImage: "arrow.triangle.2.circlepath")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                } else if let status = ytDlpUpdateStatus {
                    if status.updateAvailable {
                        Text("yt-dlp \(status.installedVersion) · \(status.latestVersion) available")
                            .uiFont(.system(size: 11))
                        Button {
                            downloadYtDlp(autoSubmit: false)
                        } label: {
                            Label("Update yt-dlp", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 28, fontSize: 12, fillsWidth: false))
                        .disabled(isLoading)
                        Text("The update is stored in dBrief's support folder.")
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.secondary.color)
                    } else {
                        Text("yt-dlp \(status.installedVersion) is up to date")
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.secondary.color)
                    }
                } else if let error = ytDlpUpdateCheckError {
                    Text("Could not check yt-dlp updates: \(error)")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                    Button("Check again") {
                        Task { await checkYtDlpUpdate() }
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 28, fontSize: 12, fillsWidth: false))
                }

                if let error = ytDlpDownloadError {
                    Text(error)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(status.danger.color)
                }
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

    private func checkYtDlpUpdate() async {
        isCheckingYtDlpUpdate = true
        ytDlpUpdateStatus = nil
        ytDlpUpdateCheckError = nil
        do {
            ytDlpUpdateStatus = try await YouTubeDownloadService.checkYtDlpUpdate()
        } catch {
            ytDlpUpdateCheckError = error.localizedDescription
        }
        isCheckingYtDlpUpdate = false
    }

    private func downloadYtDlp(autoSubmit: Bool = true) {
        isDownloadingYtDlp = true
        ytDlpDownloadError = nil
        ytDlpDownloadProgress = 0
        Task {
            do {
                for try await progress in YouTubeDownloadService.downloadYtDlp() {
                    ytDlpDownloadProgress = progress
                }
                ytDlpAvailable = true
                if !autoSubmit { await checkYtDlpUpdate() }
                // Auto-submit if the user already typed a URL
                if autoSubmit && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submitURL()
                }
            } catch {
                ytDlpDownloadError = error.localizedDescription
            }
            isDownloadingYtDlp = false
        }
    }
}
