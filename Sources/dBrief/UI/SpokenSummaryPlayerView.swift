import SwiftUI

/// Sheet presented after the user asks for a spoken summary. Shows pipeline
/// progress, then a compact audio player with Save / Discard, or an error.
struct SpokenSummaryPlayerView: View {
    let service: SpokenSummaryService
    @Bindable var bindableAudioPlayer: AudioPlayer
    var onSave: () async -> Void
    var onClose: () -> Void
    var onRetry: () -> Void

    @State private var isSaving = false

    init(service: SpokenSummaryService,
         audioPlayer: AudioPlayer,
         onSave: @escaping () async -> Void,
         onClose: @escaping () -> Void,
         onRetry: @escaping () -> Void) {
        self.service = service
        self.bindableAudioPlayer = audioPlayer
        self.onSave = onSave
        self.onClose = onClose
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Label("Spoken Summary", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Button { stopAndClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            switch service.phase {
            case .idle:
                ProgressView()
            case .rewriting:
                phaseRow("Writing a spoken script…")
            case .preparingVoice(let progress):
                if let progress {
                    VStack(spacing: 6) {
                        Text("Preparing voice model…").foregroundStyle(.secondary)
                        ProgressView(value: progress)
                    }
                } else {
                    phaseRow("Preparing voice model…")
                }
            case .synthesizing:
                phaseRow("Generating audio…")
            case .ready(let audioURL, _):
                playerControls(audioURL: audioURL)
            case .failed(let message):
                errorView(message)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onDisappear { bindableAudioPlayer.stop() }
    }

    private func phaseRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func playerControls(audioURL: URL) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Button {
                    bindableAudioPlayer.togglePlayPause(url: audioURL)
                } label: {
                    Image(systemName: bindableAudioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { bindableAudioPlayer.currentTime },
                            set: { bindableAudioPlayer.seek(to: $0) }
                        ),
                        in: 0...max(bindableAudioPlayer.duration, 0.1)
                    )
                    HStack {
                        Text(bindableAudioPlayer.formattedCurrentTime)
                        Spacer()
                        Text(bindableAudioPlayer.formattedDuration)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Discard", role: .destructive) { stopAndClose() }
                Spacer()
                Button {
                    Task { isSaving = true; await onSave(); isSaving = false }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Close") { stopAndClose() }
                Button("Retry") { onRetry() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func stopAndClose() {
        bindableAudioPlayer.stop()
        onClose()
    }
}
