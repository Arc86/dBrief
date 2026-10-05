import SwiftUI

/// No transcript to show. A recording that was never transcribed offers
/// Transcribe; a saved transcript whose view failed to load offers Rebuild.
struct ViewerNoTranscriptState: View {
    /// Transcript text is saved, so the view can be rebuilt from it.
    let canRebuild: Bool
    /// A reprocessing attempt is pending for this recording.
    let isPending: Bool
    /// Reprocessing is not available yet (recovery still loading).
    let isBusy: Bool
    let onRebuild: () -> Void
    let onTranscribe: () -> Void

    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: canRebuild ? "exclamationmark.triangle" : "waveform")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(palette.secondary.color)
                .accessibilityHidden(true)
            Text(title)
                .uiFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.heading.color)
                .multilineTextAlignment(.center)
            Text(message)
                .uiFont(.system(size: 13))
                .foregroundStyle(palette.secondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !isPending {
                Group {
                    if canRebuild {
                        Button(action: onRebuild) {
                            Label("Rebuild transcript", systemImage: "arrow.clockwise")
                        }
                    } else {
                        Button(action: onTranscribe) {
                            Label("Transcribe…", systemImage: "text.badge.plus")
                        }
                    }
                }
                .buttonStyle(ViewerBrandButtonStyle(height: 38))
                .disabled(isBusy)
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .modifier(ViewerCard())
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        if isPending { return "Transcription pending" }
        return canRebuild ? "Transcript view couldn't be loaded" : "Not transcribed yet"
    }

    private var message: String {
        if isPending { return "Manage the pending attempt in Queue & Recovery." }
        return canRebuild
            ? "The transcript text is saved. Rebuild the view from it."
            : "Transcribe this recording to see its transcript, summary and actions."
    }
}

/// Live status at the top of the live transcript card. Reads the processing
/// steps itself, so progress ticks re-render only this row, not the viewer.
struct ViewerLiveStatus: View {
    let appState: AppState
    let isProcessing: Bool
    let segmentCount: Int

    @Environment(\.viewerPalette) private var palette

    var body: some View {
        let step = isProcessing ? appState.processingSteps.first {
            if case .inProgress = $0.status { return true }
            return false
        } : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PulsingDot(color: isProcessing ? Brand.processing : Brand.recording, size: 8)
                Text(isProcessing ? (step?.name ?? "Processing…") : "Recording — live transcript")
                    .uiFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Spacer()
                Text("\(segmentCount) segments")
                    .uiFont(.caption.monospacedDigit())
                    .foregroundStyle(palette.secondary.color)
            }
            if let progress = step?.progress {
                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(palette.accentText.color)
            }
            if let detail = step?.detail, !detail.isEmpty {
                Text(detail)
                    .uiFont(.caption)
                    .foregroundStyle(palette.secondary.color)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}
