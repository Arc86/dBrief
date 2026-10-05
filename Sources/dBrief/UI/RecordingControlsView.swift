import SwiftUI
import AppKit
import os

private let log = Logger.recording

/// Capture controls for the menu panel: the Record hero and profile row when idle,
/// the timer, level bars, Pause/Stop and audio sources while recording.
struct RecordingControlsView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if appState.isIdle {
                recordButton
                profileRow
            }

            if appState.isRecording || appState.isPaused {
                HStack(alignment: .firstTextBaseline) {
                    Text(formattedDuration)
                        .uiFont(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(palette.heading.color)
                    Spacer()
                    HStack(spacing: 5) {
                        MenuPanelStatusDot(tone: appState.isPaused ? .warning : .danger, pulse: appState.isRecording, size: 6)
                        Text(appState.isPaused ? "Paused" : "Recording")
                            .uiFont(.system(size: 11, weight: .medium))
                            .foregroundStyle(appState.isPaused ? status.warning.color : status.danger.color)
                    }
                }
                .accessibilityElement(children: .combine)

                MenuPanelLevelBars(level: appState.peakLevel, active: appState.isRecording, height: 30)

                HStack(spacing: 8) {
                    if appState.isRecording {
                        Button { recordingManager.pauseRecording() } label: {
                            Label("Pause", systemImage: "pause")
                        }
                        .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 32))
                    } else {
                        Button { try? recordingManager.resumeRecording() } label: {
                            Label("Resume", systemImage: "play")
                        }
                        .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 32))
                    }

                    Button { Task { await recordingManager.stopRecording() } } label: {
                        Label("Stop", systemImage: "stop")
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .danger, height: 32))
                }
                .environment(\.controlActiveState, .active)

                audioSources
            }

            if (appState.isRecording || appState.isPaused),
               appSettings.obsidianEnabled,
               let recording = appState.currentRecording {
                MenuPanelHairline()
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
                errorBox(error)
            }

            if let notice = appState.durabilityNotice {
                durabilityBanner(notice)
            }
        }
    }

    // MARK: - Idle

    private var recordButton: some View {
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
            Label("Record meeting", systemImage: "mic.fill")
        }
        .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 40))
        .help("Start recording (\(appSettings.recordHotkey.displayString))")
    }

    private var profileRow: some View {
        @Bindable var settings = appSettings
        return HStack(spacing: 8) {
            Text("Profile")
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
            Menu {
                ForEach(settings.profiles) { profile in
                    Button {
                        settings.setActiveProfile(profile.id)
                    } label: {
                        if profile.id == settings.activeProfileId {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                MenuPanelSelectorLabel(text: settings.activeProfile.name)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Profile")
            .accessibilityValue(settings.activeProfile.name)

            Text(appSettings.recordHotkey.displayString)
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
                .fixedSize()
                .accessibilityLabel("Record shortcut \(appSettings.recordHotkey.displayString)")
        }
    }

    // MARK: - Recording

    private var audioSources: some View {
        HStack(spacing: 15) {
            MicrophoneInputMenu(
                selectedUID: appSettings.audioInputDeviceUID,
                activeName: appState.activeMicrophoneName,
                enabled: recordingManager.hasMicrophonePermission,
                tint: status.success.nsColor,
                select: { recordingManager.switchInputDevice(to: $0) }
            )
            .fixedSize()

            if recordingManager.hasSystemAudioPermission {
                Label("System audio", systemImage: "speaker.wave.2")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(status.success.color)
            }
            Spacer(minLength: 0)
            if appState.isLiveTranscribing {
                Button {
                    appState.pendingLiveTranscriptSelection = true
                    MenuBarPanel.open("transcript", with: openWindow)
                } label: {
                    Label("Live", systemImage: "text.viewfinder")
                }
                .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 22))
                .help("Open the live transcript")
            }
        }
    }

    // MARK: - Notices

    private func errorBox(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Error", systemImage: "exclamationmark.circle.fill")
                    .uiFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.danger.color)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                }
                .help("Copy the full error message")
                Button {
                    appState.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss error")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 22))
            ScrollView {
                Text(error)
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.text.color)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
        .padding(12)
        .background(status.dangerFill.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(status.dangerBorder.color, lineWidth: 1))
    }

    private func durabilityBanner(_ notice: String) -> some View {
        let warning = appState.durabilityNoticeIsWarning
        let tint = warning ? status.warning.color : status.success.color
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: warning ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.checkmark")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(notice)
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                if warning {
                    HStack(spacing: 8) {
                        Button("Retry recovery") {
                            Task {
                                await recordingManager.recoverInterruptedSessions()
                                await recordingManager.refreshWorkQueue()
                            }
                        }
                        .disabled(!recordingManager.canPerformLibraryWork)
                        Button("Show files") {
                            NSWorkspace.shared.open(InterruptedSessionStore.defaultRootURL)
                        }
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 26, fontSize: 11, fillsWidth: false))
                }
            }
            Spacer(minLength: 4)
            Button {
                appState.durabilityNotice = nil
                appState.durabilityNoticeIsWarning = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 18))
            .accessibilityLabel("Dismiss recovery notice")
        }
        .padding(12)
        .background(warning ? status.warning.color.opacity(0.12) : status.successFill.color,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
