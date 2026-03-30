import SwiftUI
import os

private let log = Logger.recording

struct RecordingControlsView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var settings = appSettings
        VStack(spacing: 8) {
            // Profile picker — hidden while recording
            if appState.isIdle {
                HStack {
                    Text("Profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.activeProfileId },
                            set: { settings.setActiveProfile($0) }
                        )
                    ) {
                        ForEach(settings.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 170)
                }
            }

            // REC header shown while recording
            if appState.isRecording || appState.isPaused {
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                            .opacity(appState.isRecording ? 1 : 0.3)
                            .animation(.easeInOut(duration: 0.6).repeatForever(), value: appState.isRecording)
                        Text(appState.isPaused ? "PAUSED" : "REC")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(appState.isRecording ? .red : .secondary)
                    }
                }
            }

            // Timer and level
            if appState.isRecording || appState.isPaused {
                HStack(alignment: .bottom) {
                    Text(formattedDuration)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.primary)
                    Spacer()
                    LevelMeterBars(level: appState.peakLevel)
                        .frame(width: 36, height: 20)
                }
            }

            // Controls
            HStack(spacing: 12) {
                if appState.isIdle {
                    Button {
                        appState.lastError = nil
                        Task {
                            do {
                                try await recordingManager.startRecording()
                            } catch {
                                let msg = error.localizedDescription
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
                    Button { recordingManager.pauseRecording() } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { Task { await recordingManager.stopRecording() } } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if appState.isPaused {
                    Button { try? recordingManager.resumeRecording() } label: {
                        Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { Task { await recordingManager.stopRecording() } } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            // Audio source chips
            if appState.isRecording || appState.isPaused {
                HStack(spacing: 8) {
                    Label("Mic", systemImage: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(recordingManager.hasMicrophonePermission ? .green : .secondary)
                    if recordingManager.hasSystemAudioPermission {
                        Label("System Audio", systemImage: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
            }

            if (appState.isRecording || appState.isPaused),
               appSettings.obsidianEnabled,
               let recording = appState.currentRecording {
                ObsidianFolderPicker(
                    title: "Obsidian output folder",
                    currentRelativePath: recording.obsidianFolderRelativePath ?? appSettings.effectiveObsidianDefaultFolderRelativePath
                ) { relativePath in
                    recording.obsidianFolderRelativePath = relativePath
                    if appSettings.activeProfile.isProtectedDefault {
                        appSettings.obsidianDefaultFolderRelativePath = relativePath
                    }
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

struct LevelMeterBars: View {
    let level: Float
    private let barCount = 8

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: index))
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index + 1) / Float(barCount)
        let filled = level >= threshold
        return filled ? CGFloat(4 + index * 2) : 4
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index + 1) / Float(barCount)
        if threshold > 0.85 { return .red }
        if threshold > 0.6  { return .yellow }
        return .green
    }
}
