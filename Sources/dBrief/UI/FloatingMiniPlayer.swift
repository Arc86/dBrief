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
            contentRect: NSRect(x: 0, y: 0, width: 248, height: 60),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = ""
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = MiniPlayerView()
            .environment(appState)
            .environment(recordingManager)

        let hosting = NSHostingView(rootView: content)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        // Position at top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 258
            let y = screenFrame.maxY - 76
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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.12))
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(.red)
                    .frame(width: 11, height: 11)
                    .opacity(appState.isRecording ? 1 : 0.45)
                    .animation(
                        appState.isRecording
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: appState.isRecording
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(formattedDuration)
                    .font(.system(.headline, design: .monospaced))
                    .monospacedDigit()

                MiniWaveform(level: appState.peakLevel)
                    .frame(height: 12)
            }

            Spacer()

            HStack(spacing: 8) {
                if appState.isRecording {
                    miniButton(icon: "pause.fill") {
                        recordingManager.pauseRecording()
                    }
                } else if appState.isPaused {
                    miniButton(icon: "play.fill") {
                        try? recordingManager.resumeRecording()
                    }
                }

                miniButton(icon: "stop.fill", tint: .red) {
                    Task { await recordingManager.stopRecording() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 248, height: 60)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
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

    private func miniButton(icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint ?? .primary)
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct MiniWaveform: View {
    let level: Float

    private var heights: [CGFloat] {
        let base: [CGFloat] = [6, 10, 14, 10, 6]
        let scale = CGFloat(0.5 + min(max(level, 0), 1) * 1.2)
        return base.map { $0 * scale }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { idx in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.teal.opacity(0.8), Color.blue.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3, height: heights[idx])
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
