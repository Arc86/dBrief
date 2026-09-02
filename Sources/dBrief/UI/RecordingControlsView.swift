import SwiftUI
import AppKit
import os

private let log = Logger.recording

struct RecordingControlsView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow

    @State private var inputDevices: [AudioInputDevice] = []

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

            // Timer + REC/PAUSED indicator while recording
            if appState.isRecording || appState.isPaused {
                HStack(alignment: .firstTextBaseline) {
                    Text(formattedDuration)
                        .font(.brandMono(30, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 7) {
                        BrandStatusDot(
                            color: appState.isPaused ? Brand.paused : Brand.recording,
                            size: 8,
                            pulse: appState.isRecording
                        )
                        Text(appState.isPaused ? "PAUSED" : "REC")
                            .font(.brandMono(11, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(appState.isPaused ? Brand.paused : Brand.recording)
                    }
                }

                LiveWaveStrip(level: appState.peakLevel, active: appState.isRecording)
                    .frame(height: 28)
                    .padding(.vertical, 2)
            }

            // Controls
            if appState.isIdle {
                Button {
                    appState.lastError = nil
                    Task {
                        do {
                            try await recordingManager.startRecording()
                        } catch {
                            appState.lastError = error.localizedDescription
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        RecordGlyph(size: 18)
                        Text("Record meeting")
                    }
                }
                .buttonStyle(GradientButtonStyle())

                Text("⌃ ⌥ ⌘ R")
                    .font(.brandMono(11))
                    .tracking(2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    if appState.isRecording {
                        Button { recordingManager.pauseRecording() } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(GlassControlButtonStyle())
                    } else {
                        Button { try? recordingManager.resumeRecording() } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(GlassControlButtonStyle())
                    }

                    Button { Task { await recordingManager.stopRecording() } } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(CoralControlButtonStyle())
                }
                .environment(\.controlActiveState, .active)
            }

            // Audio source chips
            if appState.isRecording || appState.isPaused {
                HStack(spacing: 8) {
                    Menu {
                        Button("System Default") { recordingManager.switchInputDevice(to: nil) }
                        Divider()
                        ForEach(inputDevices) { device in
                            Button {
                                recordingManager.switchInputDevice(to: device.uid)
                            } label: {
                                if device.uid == appSettings.audioInputDeviceUID {
                                    Label(device.displayName, systemImage: "checkmark")
                                } else {
                                    Text(device.displayName)
                                }
                            }
                        }
                    } label: {
                        Label("Mic", systemImage: "mic.fill")
                            .font(.caption2)
                            .foregroundStyle(recordingManager.hasMicrophonePermission ? .green : .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .onAppear { inputDevices = AudioInputDeviceManager.availableInputDevices() }

                    if recordingManager.hasSystemAudioPermission {
                        Label("System Audio", systemImage: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    if appState.isLiveTranscribing {
                        Button {
                            appState.pendingLiveTranscriptSelection = true
                            openWindow(id: "transcript")
                            NSApp.activate(ignoringOtherApps: true)
                        } label: {
                            Label("Live Transcript", systemImage: "text.viewfinder")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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

            if let notice = appState.durabilityNotice {
                let noticeColor: Color = appState.durabilityNoticeIsWarning ? .orange : .green
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: appState.durabilityNoticeIsWarning
                        ? "externaldrive.badge.exclamationmark"
                        : "externaldrive.badge.checkmark")
                        .foregroundStyle(noticeColor)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        appState.durabilityNotice = nil
                        appState.durabilityNoticeIsWarning = false
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityLabel("Dismiss recovery notice")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(noticeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// Full-width live "waveform" for the recording state: a row of brand-gradient
/// bars whose heights breathe with the current peak level. Purely cosmetic — a
/// deterministic per-bar profile gives the wave shape, scaled by `level`.
struct LiveWaveStrip: View {
    let level: Float
    var active: Bool
    @Environment(\.calmAppearance) private var calm
    private let barCount = 34

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Brand.accentFill(calm: calm))
                        .frame(width: barWidth, height: barHeight(i, maxH: geo.size.height))
                        .opacity(active ? 1 : 0.4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }

    private func barHeight(_ i: Int, maxH: CGFloat) -> CGFloat {
        // A smooth standing-wave profile (two sines) so the strip has shape even
        // at a steady level; scaled by the live peak with a small floor.
        let phase = Double(i) / Double(barCount) * .pi * 4
        let profile = (sin(phase) * 0.5 + 0.5) * 0.6 + (sin(phase * 0.5) * 0.5 + 0.5) * 0.4
        let lvl = CGFloat(max(0.06, min(1, level)))
        let h = (0.18 + 0.82 * CGFloat(profile) * lvl) * maxH
        return max(3, h)
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
