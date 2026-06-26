import SwiftUI

/// Sheet presented after the user asks for a spoken summary. Shows pipeline
/// progress, then a compact audio player with Save / Discard (fresh generation)
/// or a single Done button (replaying an already-saved summary), or an error.
/// Styled with the dBrief brand kit (neon accents, glass card, gradient CTA).
struct SpokenSummaryPlayerView: View {
    let service: SpokenSummaryService
    @Bindable var bindableAudioPlayer: AudioPlayer
    var onSave: () async -> Void
    var onClose: () -> Void
    var onRetry: () -> Void

    @Environment(\.calmAppearance) private var calm
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
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider().opacity(0.4)
            content
        }
        .padding(22)
        .frame(width: 440)
        .onDisappear { bindableAudioPlayer.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            BrandStatusDot(color: Brand.violet, size: 8)
            BrandKicker("Spoken Summary")
            Spacer()
            Button { stopAndClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Phase content

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .idle:
            phaseRow("Preparing…")
        case .rewriting:
            phaseRow("Writing a spoken script…")
        case .preparingVoice(let progress):
            if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preparing voice model…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .tint(Brand.violet)
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

    private func phaseRow(_ text: String) -> some View {
        HStack(spacing: 11) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    // MARK: - Player

    private func playerControls(audioURL: URL) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Button {
                    bindableAudioPlayer.togglePlayPause(url: audioURL)
                } label: {
                    Image(systemName: bindableAudioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Brand.accentFill(calm: calm))
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
                    .tint(Brand.violet)
                    HStack {
                        Text(bindableAudioPlayer.formattedCurrentTime)
                        Spacer()
                        Text(bindableAudioPlayer.formattedDuration)
                    }
                    .font(.brandMono(11))
                    .foregroundStyle(.secondary)
                }
            }
            .glassCard(cornerRadius: 14, padding: 14)

            if service.resultIsSaved {
                Button { stopAndClose() } label: { Text("Done") }
                    .buttonStyle(GlassControlButtonStyle())
            } else {
                HStack(spacing: 12) {
                    Button("Discard", role: .destructive) { stopAndClose() }
                        .buttonStyle(CoralControlButtonStyle())
                    Button {
                        Task { isSaving = true; await onSave(); isSaving = false }
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.coral)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .glassCard(cornerRadius: 12, padding: 12)

            HStack(spacing: 12) {
                Button("Close") { stopAndClose() }
                    .buttonStyle(GlassControlButtonStyle())
                Button { onRetry() } label: { Text("Retry") }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func stopAndClose() {
        bindableAudioPlayer.stop()
        onClose()
    }
}
