import SwiftUI
import os

private let log = Logger(subsystem: "com.voicerecorder.app", category: "recording")

struct RecordingControlsView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        VStack(spacing: 8) {
            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
                Spacer()
            }

            // Timer and level
            if appState.isRecording || appState.isPaused {
                HStack {
                    Text(formattedDuration)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.primary)

                    Spacer()

                    // Level meter
                    LevelMeter(level: appState.peakLevel)
                        .frame(width: 60, height: 12)
                }
            }

            // Controls
            HStack(spacing: 12) {
                if appState.isIdle {
                    Button {
                        appState.lastError = nil
                        Task {
                            do {
                                log.info("Starting recording...")
                                try await recordingManager.startRecording()
                                log.info("Recording started")
                            } catch {
                                let msg = error.localizedDescription
                                log.error("Record failed: \(msg, privacy: .public)")
                                fputs("[DeBrief] Record failed: \(msg)\n", stderr)
                                appState.lastError = msg
                            }
                        }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if appState.isRecording {
                    Button {
                        recordingManager.pauseRecording()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            await recordingManager.stopRecording()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if appState.isPaused {
                    Button {
                        try? recordingManager.resumeRecording()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            await recordingManager.stopRecording()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            if (appState.isRecording || appState.isPaused),
               appSettings.obsidianEnabled,
               let recording = appState.currentRecording {
                ObsidianFolderPicker(
                    title: "Obsidian output folder",
                    currentRelativePath: recording.obsidianFolderRelativePath ?? appSettings.obsidianDefaultFolderRelativePath
                ) { relativePath in
                    recording.obsidianFolderRelativePath = relativePath
                    appSettings.obsidianDefaultFolderRelativePath = relativePath
                }
            }

            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private var statusColor: Color {
        switch appState.recordingState {
        case .idle: .secondary
        case .recording: .red
        case .paused: .orange
        case .processing: .blue
        }
    }

    private var statusText: String {
        switch appState.recordingState {
        case .idle: "Ready"
        case .recording: "Recording"
        case .paused: "Paused"
        case .processing: "Processing"
        }
    }

    private var formattedDuration: String {
        let total = Int(appState.recordingDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 2)
                    .fill(meterColor)
                    .frame(width: max(0, geo.size.width * CGFloat(min(level, 1.0))))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    private var meterColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }
}
