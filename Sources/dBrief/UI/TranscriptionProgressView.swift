import SwiftUI
import dBriefWire
import AppKit

struct TranscriptionProgressView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    var onCancel: (() async -> Void)?
    @State private var copied = false
    @State private var memStats: (used: Int64, free: Int64, total: Int64)? = nil
    @State private var memTimer: Timer? = nil

    private var hasInProgressStep: Bool {
        appState.processingSteps.contains { if case .inProgress = $0.status { return true }; return false }
    }

    private var isComplete: Bool {
        !appState.processingSteps.isEmpty && appState.processingSteps.allSatisfy {
            if case .completed = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }
    }

    /// Shown only under real memory pressure: the system says critical, or more
    /// than 85 % of RAM is in use. Otherwise memory is not the user's concern.
    @ViewBuilder
    private var memoryBar: some View {
        if let stats = memStats, stats.total > 0 {
            let fraction = Double(stats.used) / Double(stats.total)
            if appState.memoryPressureLevel == .critical || fraction > 0.85 {
                let usedGB = Double(stats.used) / 1_073_741_824
                let totalGB = Double(stats.total) / 1_073_741_824
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "memorychip")
                            .foregroundStyle(status.warning.color)
                        Text("Memory is running low")
                            .uiFont(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.heading.color)
                        Spacer()
                        Text(String(format: "%.1f / %.0f GB", usedGB, totalGB))
                            .uiFont(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(palette.secondary.color)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.divider.color)
                            Capsule()
                                .fill(status.warning.color)
                                .frame(width: geo.size.width * CGFloat(min(fraction, 1.0)))
                                .animation(.linear(duration: 0.3), value: fraction)
                        }
                    }
                    .frame(height: 3)
                    Text("Processing may slow down. Closing other apps helps.")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                }
                .padding(10)
                .background(status.warning.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Memory is running low")
                .accessibilityValue(String(format: "%.1f of %.0f gigabytes used", usedGB, totalGB))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(isComplete ? "Processing complete" : "Processing recording")
                    .uiFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Spacer()
                if let done = MenuPanelProgress.doneLabel(appState.processingSteps) {
                    Text(done)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(appState.processingSteps) { step in
                    stepRow(step)
                }
            }

            if let liveText = appState.liveInferenceText {
                ScrollView {
                    Text(liveText)
                        .uiFont(.system(.caption, design: .monospaced))
                        .foregroundStyle(palette.secondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .padding(8)
                }
                .frame(maxHeight: 150)
                .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.divider.color, lineWidth: 1))
            }

            memoryBar

            HStack(spacing: 8) {
                if hasInProgressStep, let onCancel {
                    Button {
                        Task { await onCancel() }
                    } label: {
                        Label(MenuPanelProgress.stopProcessingTitle(isCapturing: !appState.isIdle), systemImage: "stop")
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .danger, height: 30, fillsWidth: false))
                    .accessibilityLabel("Stop processing")
                    .help("Stop processing; saved progress remains available for recovery")
                }

                if let title = appState.processingJob?.transcriptButtonTitle {
                    Button {
                        appState.pendingLiveTranscriptSelection = true
                        MenuBarPanel.open("transcript", with: openWindow)
                    } label: {
                        Label(title, systemImage: "text.viewfinder")
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30))
                }

                if appState.pendingSpeakerReview != nil {
                    Button {
                        SpeakerReviewWindowController.shared.show()
                    } label: {
                        Label("Review speakers", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 30, fontSize: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isComplete, let recording = appState.processingRecording, recording.transcription != nil {
                MenuPanelHairline()
                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy notes") {
                        if
                            let transcript = recording.transcription?.text,
                            let summary = recording.summary
                        {
                            let insights = LocalInsightsResult(
                                summary: summary,
                                actionItems: recording.actionItems ?? [],
                                tags: recording.tags ?? [],
                                sentiment: recording.sentiment ?? "Neutral"
                            )
                            let markdown = ObsidianFormatter.format(transcript: transcript, insights: insights)
                            Task {
                                copied = await RecordingClipboard.copy(markdown, for: recording)
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } else if let text = recording.transcription?.text {
                            Task {
                                copied = await RecordingClipboard.copy(text, for: recording)
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        }
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30))

                    Button("Close") {
                        appState.processingSteps.removeAll()
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30))
                }
            }
        }
        .onAppear {
            memStats = MemoryPressureMonitor.getMemoryStats()
            memTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    memStats = MemoryPressureMonitor.getMemoryStats()
                }
            }
        }
        .onDisappear {
            memTimer?.invalidate()
            memTimer = nil
        }
    }

    private func stepRow(_ step: ProcessingStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                stepIcon(for: step.status)
                    .frame(width: 18, height: 18)
                Text(step.name)
                    .uiFont(.system(size: 13))
                    .foregroundStyle(isDone(step.status) ? palette.secondary.color : palette.heading.color)
                Spacer()
            }
            if case .inProgress = step.status, let progress = step.progress {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(palette.primary.color)
                    .frame(height: 4)
                    .padding(.leading, 28)
                    .padding(.top, 2)
                    .animation(.linear(duration: 0.3), value: progress)
            }
            if case .inProgress = step.status, let detail = step.detail, !detail.isEmpty {
                Text(detail)
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                    .padding(.leading, 28)
            }
            if case .failed(let message) = step.status, !message.isEmpty {
                ScrollView {
                    Text(message)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(status.danger.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 60)
                .padding(.leading, 28)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func isDone(_ status: ProcessingStep.Status) -> Bool {
        if case .completed = status { return true }
        return false
    }

    @ViewBuilder
    private func stepIcon(for stepStatus: ProcessingStep.Status) -> some View {
        switch stepStatus {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 15))
                .foregroundStyle(palette.divider.color)
                .accessibilityLabel("Waiting")
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .tint(palette.primary.color)
                .accessibilityLabel("In progress")
        case .completed:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(status.success.color)
                .accessibilityLabel("Done")
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(status.danger.color)
                .accessibilityLabel("Failed")
        }
    }
}
