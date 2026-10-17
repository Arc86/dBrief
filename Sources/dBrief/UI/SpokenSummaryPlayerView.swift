import SwiftUI

/// Sheet presented after the user asks for a spoken summary. Shows pipeline
/// progress, then a compact audio player with Save / Discard (fresh generation)
/// or a single Done button (replaying an already-saved summary), or an error.
/// Uses the viewer palette, assistant-panel header and player-bar controls so
/// it reads as part of the transcript viewer.
struct SpokenSummaryPlayerView: View {
    let phase: SpokenSummaryService.Phase
    let isSaved: Bool
    var recordingTitle: String?
    @Bindable var bindableAudioPlayer: AudioPlayer
    var onSave: () async -> Void
    var onClose: () -> Void
    var onRetry: () -> Void

    @Environment(\.viewerPalette) private var palette
    @State private var isSaving = false

    init(phase: SpokenSummaryService.Phase,
         isSaved: Bool,
         recordingTitle: String? = nil,
         audioPlayer: AudioPlayer,
         onSave: @escaping () async -> Void,
         onClose: @escaping () -> Void,
         onRetry: @escaping () -> Void) {
        self.phase = phase
        self.isSaved = isSaved
        self.recordingTitle = recordingTitle
        self.bindableAudioPlayer = audioPlayer
        self.onSave = onSave
        self.onClose = onClose
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
        }
        .padding(20)
        .frame(width: 440)
        .background(palette.surface.color)
        .onDisappear { bindableAudioPlayer.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(LinearGradient(colors: palette.brandStops.map(\.color),
                                                startPoint: .leading, endPoint: .trailing))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Spoken summary")
                    .uiFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Text(recordingTitle ?? "This recording")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button { stopAndClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary.color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Escape must never throw away unsaved audio; Discard is explicit.
            .keyboardShortcut(holdsUnsavedAudio ? nil : .cancelAction)
            .accessibilityLabel(holdsUnsavedAudio ? "Discard spoken summary" : "Close spoken summary")
            .help("Close")
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { palette.divider.color.frame(height: 1) }
    }

    private var holdsUnsavedAudio: Bool {
        if case .ready = phase { return !isSaved }
        return false
    }

    // MARK: - Phase content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready(let audioURL, _):
            playerControls(audioURL: audioURL)
        case .failed(let message):
            errorView(message)
        default:
            progressSteps
        }
    }

    private enum StepState { case pending, active, done }

    /// Index of the running step: 0 script, 1 voice, 2 audio.
    private var activeStep: Int {
        switch phase {
        case .idle, .rewriting: 0
        case .preparingVoice: 1
        default: 2
        }
    }

    private var progressSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step("Write a spoken script", index: 0)
            step("Prepare the voice", index: 1, progress: voiceProgress)
            step("Generate audio", index: 2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spoken summary progress")
    }

    private var voiceProgress: Double? {
        if case .preparingVoice(let progress) = phase { return progress }
        return nil
    }

    private func step(_ title: String, index: Int, progress: Double? = nil) -> some View {
        let state: StepState = index < activeStep ? .done : index == activeStep ? .active : .pending
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.accentText.color)
                case .active:
                    ProgressView().controlSize(.small)
                case .pending:
                    Circle()
                        .strokeBorder(palette.divider.color, lineWidth: 1.5)
                        .frame(width: 13, height: 13)
                }
            }
            .frame(width: 18, height: 18)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(state == .active ? "\(title)…" : title)
                        .uiFont(.system(size: 13, weight: state == .active ? .medium : .regular))
                        .foregroundStyle(state == .active ? palette.heading.color : palette.secondary.color)
                    if state == .active, let progress {
                        Spacer(minLength: 8)
                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            .uiFont(.system(size: 12).monospacedDigit())
                            .foregroundStyle(palette.secondary.color)
                    }
                }
                if state == .active, let progress {
                    SpokenSummaryTrack(fraction: progress)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Done" : state == .active ? "In progress" : "Waiting")
    }

    // MARK: - Player

    private func playerControls(audioURL: URL) -> some View {
        VStack(alignment: .trailing, spacing: 18) {
            HStack(spacing: 12) {
                Button {
                    bindableAudioPlayer.togglePlayPause(url: audioURL)
                } label: {
                    Image(systemName: bindableAudioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.accentText.color)
                        .frame(width: 17, height: 17)
                        .frame(width: 38, height: 38)
                        .background(palette.surface.color, in: Circle())
                        .overlay(Circle().strokeBorder(palette.accentText.color.opacity(0.48), lineWidth: 1.2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(bindableAudioPlayer.isPlaying ? "Pause spoken summary" : "Play spoken summary")

                Text(bindableAudioPlayer.formattedCurrentTime)
                    .uiFont(.system(size: 12).monospacedDigit())
                    .foregroundStyle(palette.secondary.color)
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityLabel("Elapsed time \(bindableAudioPlayer.formattedCurrentTime)")

                SpokenSummaryScrubber(
                    time: bindableAudioPlayer.currentTime,
                    duration: bindableAudioPlayer.duration,
                    onSeek: { bindableAudioPlayer.seek(to: $0) }
                )

                Text(bindableAudioPlayer.formattedDuration)
                    .uiFont(.system(size: 12).monospacedDigit())
                    .foregroundStyle(palette.secondary.color)
                    .frame(minWidth: 34, alignment: .leading)
                    .accessibilityLabel("Duration \(bindableAudioPlayer.formattedDuration)")
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.divider.color, lineWidth: 1))

            if isSaved {
                Button("Done") { stopAndClose() }
                    .buttonStyle(ViewerCommandButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 8) {
                    Button("Discard", role: .destructive) { stopAndClose() }
                    .buttonStyle(ViewerCommandButtonStyle())
                    .disabled(isSaving)
                    Button {
                        Task { isSaving = true; await onSave(); isSaving = false }
                    } label: {
                        HStack(spacing: 6) {
                            if isSaving {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                            }
                            Text(isSaving ? "Saving…" : "Save")
                        }
                    }
                    .buttonStyle(ViewerBrandButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .trailing, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't create the spoken summary")
                        .uiFont(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.heading.color)
                    Text(message)
                        .uiFont(.system(size: 12))
                        .foregroundStyle(palette.text.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.divider.color, lineWidth: 1))

            HStack(spacing: 8) {
                Button("Close") { stopAndClose() }
                    .buttonStyle(ViewerCommandButtonStyle())
                Button("Retry") { onRetry() }
                    .buttonStyle(ViewerBrandButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func stopAndClose() {
        bindableAudioPlayer.stop()
        onClose()
    }
}

/// Palette-drawn progress track; native linear progress loses its tint in an
/// inactive window and its track disappears on light surfaces.
private struct SpokenSummaryTrack: View {
    let fraction: Double
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(palette.divider.color)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(palette.primary.color)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Seekable playback track in the same style, adjustable by keyboard and VoiceOver.
private struct SpokenSummaryScrubber: View {
    let time: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @Environment(\.viewerPalette) private var palette
    @State private var hovering = false

    private var fraction: Double { duration > 0 ? min(max(time / duration, 0), 1) : 0 }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                SpokenSummaryTrack(fraction: fraction)
                Circle()
                    .fill(palette.surface.color)
                    .overlay(Circle().strokeBorder(palette.primary.color, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, min(width - 12, width * fraction - 6)))
                    .opacity(hovering || fraction > 0 ? 1 : 0)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0, width > 0 else { return }
                onSeek(min(max(value.location.x / width, 0), 1) * duration)
            })
        }
        .frame(height: 20)
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(time)) of \(Int(duration)) seconds")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(time + 5, duration))
            case .decrement: onSeek(max(time - 5, 0))
            @unknown default: break
            }
        }
    }
}
