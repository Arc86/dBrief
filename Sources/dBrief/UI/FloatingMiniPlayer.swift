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
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = MiniPlayerView()
            .environment(appState)
            .environment(recordingManager)

        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting

        // Position at top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 232
            let y = screenFrame.maxY - 132
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
        VStack(spacing: 8) {
            // Top row: status + timer
            HStack {
                HStack(spacing: 5) {
                    appIcon
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .opacity(0.8)

                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .opacity(appState.isRecording ? 1 : 0.5)
                        .animation(
                            appState.isRecording
                                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                : .default,
                            value: appState.isRecording
                        )

                    Text(appState.isRecording ? "Recording" : "Paused")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(formattedDuration)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            // Waveform
            MiniWaveform(level: appState.peakLevel)
                .frame(height: 20)
                .frame(maxWidth: .infinity)

            // Bottom: action buttons
            HStack(spacing: 6) {
                if appState.isRecording {
                    Button {
                        recordingManager.pauseRecording()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                } else if appState.isPaused {
                    Button {
                        try? recordingManager.resumeRecording()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }

                Button {
                    Task { await recordingManager.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.8))
            }
        }
        .padding(12)
        .frame(width: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private var appIcon: Image {
        if let url = Bundle.main.url(forResource: "dBrief-Icon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            return Image(nsImage: nsImage)
        }
        if let nsImage = NSImage(named: "AppIcon") {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "waveform.circle.fill")
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

private struct MiniWaveform: View {
    let level: Float
    private let barCount = 20

    private var heights: [CGFloat] {
        let clamped = CGFloat(min(max(level, 0), 1))
        return (0..<barCount).map { i in
            // Create a natural wave pattern that responds to level
            let position = Double(i) / Double(barCount - 1)
            let wave = sin(position * .pi) // bell curve shape
            let base: CGFloat = 2
            let maxExtra: CGFloat = 16
            return base + maxExtra * wave * (0.2 + clamped * 0.8)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { idx in
                Capsule()
                    .fill(.tint)
                    .frame(width: 2.5, height: heights[idx])
            }
        }
        .tint(.blue.opacity(0.7))
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
