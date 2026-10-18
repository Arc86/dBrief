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
                        .keyboardShortcut(CaptureShortcut.pauseResume)
                        .help("Pause recording (⌥⌘P)")
                    } else {
                        Button { recordingManager.requestResume() } label: {
                            Label("Resume", systemImage: "play")
                        }
                        .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 32))
                        .keyboardShortcut(CaptureShortcut.pauseResume)
                        .help("Resume recording (⌥⌘P)")
                    }

                    Button { Task { await recordingManager.stopRecording() } } label: {
                        Label("Stop", systemImage: "stop")
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .danger, height: 32))
                    .keyboardShortcut(CaptureShortcut.stop)
                    .help("Stop recording (⌥⌘.)")
                }
                .environment(\.controlActiveState, .active)

                audioSources
                // Mic switches and problems (a silent or muted mic) also show here, not
                // only in the optional floating window.
                if let note = appState.recordingStatusNote {
                    Label(note, systemImage: appState.recordingStatusNoteIsProblem
                          ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(appState.recordingStatusNoteIsProblem ? status.warning.color : palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if (appState.isRecording || appState.isPaused),
               appSettings.obsidianEnabled,
               let recording = appState.currentRecording {
                MenuPanelHairline()
                ObsidianFolderPicker(
                    title: "Obsidian output folder",
                    currentRelativePath: recording.obsidianFolderRelativePath ?? appSettings.effectiveObsidianDefaultFolderRelativePath
                ) { relativePath in
                    // This recording only; the default lives in Settings → Integrations.
                    recording.obsidianFolderRelativePath = relativePath
                }
            }

            NoticeStack(notices: appState.notices.items)
        }
    }

    // MARK: - Idle

    private var recordButton: some View {
        Button {
            Task { await recordingManager.requestRecording() }
        } label: {
            Label("Record meeting", systemImage: "mic.fill")
                .frame(maxWidth: .infinity)
                // The shortcut rides inside the button it triggers, quiet and right-aligned.
                .overlay(alignment: .trailing) {
                    Text(appSettings.recordHotkey.displayString)
                        .uiFont(.system(size: 11, weight: .medium))
                        .opacity(0.55)
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 40))
        .keyboardShortcut("r", modifiers: .command)
        .help("Start recording (\(appSettings.recordHotkey.displayString))")
        .accessibilityHint("Shortcut \(appSettings.recordHotkey.displayString)")
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
                    appState.pendingLiveTranscriptSelection = .capture
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

    private var formattedDuration: String { appState.recordingDuration.formattedDuration }
}
