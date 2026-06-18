import SwiftUI
import dBriefWire
import AppKit

struct TranscriptionProgressView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
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

    @ViewBuilder
    private var memoryBar: some View {
        if let stats = memStats, stats.total > 0 {
            let fraction = Double(stats.used) / Double(stats.total)
            let usedGB = Double(stats.used) / 1_073_741_824
            let totalGB = Double(stats.total) / 1_073_741_824
            let color: Color = fraction > 0.85 ? .red : fraction > 0.6 ? .yellow : .green

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Memory")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f / %.0f GB", usedGB, totalGB))
                        .font(.caption2)
                        .foregroundStyle(fraction > 0.6 ? color : .secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(min(fraction, 1.0)))
                            .animation(.linear(duration: 0.3), value: fraction)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isComplete ? "Processing Complete" : "Processing...")
                .font(.headline)

            ForEach(appState.processingSteps) { step in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        stepIcon(for: step.status)
                            .frame(width: 16)
                        Text(step.name)
                            .font(.callout)
                        Spacer()
                        if case .inProgress = step.status, appState.memoryPressureLevel != .normal {
                            Text("⚠ Low RAM")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                    if case .inProgress = step.status, let progress = step.progress {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(height: 4)
                            .padding(.leading, 24)
                            .animation(.linear(duration: 0.3), value: progress)
                    }
                    if case .failed(let message) = step.status, !message.isEmpty {
                        ScrollView {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 60)
                        .padding(.leading, 24)
                    }
                }
            }
            
            if let liveText = appState.liveInferenceText {
                Divider()
                ScrollView {
                    Text(liveText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxHeight: 150)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }

            memoryBar

            HStack {
                if hasInProgressStep, let onCancel {
                    Button {
                        Task { await onCancel() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }

                if !appState.liveTranscriptSegments.isEmpty {
                    Button {
                        appState.pendingLiveTranscriptSelection = true
                        openWindow(id: "transcript")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Live Transcript", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if appState.pendingSpeakerReview != nil {
                    Button {
                        openWindow(id: "speaker-review")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Review speakers", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isComplete, let recording = appState.currentRecording, recording.transcription != nil {
                Divider()
                HStack {
                    Button(copied ? "Copied!" : "Copy Notes") {
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
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(markdown, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } else if let text = recording.transcription?.text {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button("Close") {
                        appState.processingSteps.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
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

    @ViewBuilder
    private func stepIcon(for status: ProcessingStep.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
