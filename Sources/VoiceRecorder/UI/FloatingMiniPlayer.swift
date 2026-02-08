import SwiftUI
import AppKit

/// Manages a small floating window that shows recording status.
@MainActor
@Observable
final class FloatingMiniPlayerController {
    private var window: NSPanel?
    private var appState: AppState?
    private var recordingManager: RecordingManager?

    func setUp(appState: AppState, recordingManager: RecordingManager) {
        self.appState = appState
        self.recordingManager = recordingManager
    }

    func show() {
        guard window == nil, let appState, let recordingManager else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false

        let content = MiniPlayerView()
            .environment(appState)
            .environment(recordingManager)

        panel.contentView = NSHostingView(rootView: content)

        // Position at top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 230
            let y = screenFrame.maxY - 58
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.window = panel
    }

    func dismiss() {
        window?.close()
        window = nil
    }

    var isVisible: Bool {
        window != nil
    }
}

private struct MiniPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing red dot
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(appState.isRecording ? 1 : 0.4)
                .animation(
                    appState.isRecording
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: appState.isRecording
                )

            // Duration
            Text(formattedDuration)
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()

            Spacer()

            // Pause/Resume
            if appState.isRecording {
                Button {
                    recordingManager.pauseRecording()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            } else if appState.isPaused {
                Button {
                    try? recordingManager.resumeRecording()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            // Stop
            Button {
                Task { await recordingManager.stopRecording() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 220, height: 48)
        .background(.ultraThinMaterial)
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
