import SwiftUI
import AppKit
import OSLog

/// Manages a small floating window that shows recording status.
@MainActor
@Observable
final class FloatingMiniPlayerController {
    private static let panelWidth: CGFloat = 220
    private static let screenMargin: CGFloat = 12

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
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
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
            .environment(self)

        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting

        // Size panel to fit SwiftUI content
        let fittingSize = hosting.fittingSize
        panel.setContentSize(CGSize(width: Self.panelWidth, height: fittingSize.height))

        // Position at top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - Self.panelWidth - Self.screenMargin
            let y = screenFrame.maxY - fittingSize.height - Self.screenMargin
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.window = panel
    }

    func dismiss() {
        window?.close()
        window = nil
        isCollapsed = false
    }

    var isVisible: Bool {
        window != nil
    }

    // --- collapse support ---
    var isCollapsed: Bool = false

    func toggleCollapse() {
        isCollapsed.toggle()
        Task { @MainActor [weak self] in
            self?.updatePanelSize()
        }
    }

    private func updatePanelSize() {
        guard let window, let screen = NSScreen.main else { return }
        let fittingHeight = window.contentView?.fittingSize.height ?? 0
        let newSize = CGSize(width: Self.panelWidth, height: fittingHeight)
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - Self.panelWidth - Self.screenMargin
        let y = screenFrame.maxY - fittingHeight - Self.screenMargin
        window.setContentSize(newSize)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct MiniPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(FloatingMiniPlayerController.self) private var controller

    private static let cachedIcon: Image = {
        if let url = Bundle.main.url(forResource: "dBrief-Icon", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return Image(nsImage: img) }
        if let img = NSImage(named: "AppIcon") { return Image(nsImage: img) }
        return Image(systemName: "waveform.circle.fill")
    }()

    var body: some View {
        VStack(spacing: 8) {
            // Top row: status + timer
            HStack {
                HStack(spacing: 5) {
                    Self.cachedIcon
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
                    .foregroundStyle(.primary)

                Button {
                    controller.toggleCollapse()
                } label: {
                    Image(systemName: controller.isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            if !controller.isCollapsed {
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
                        do {
                            try recordingManager.resumeRecording()
                        } catch {
                            Logger.recording.error("Failed to resume recording: \(error)")
                        }
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
            } // end if !controller.isCollapsed
        }
        .padding(12)
        .frame(width: 220)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
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

    @State private var history: [Float] = Array(repeating: 0, count: 20)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { idx in
                Capsule()
                    .fill(.tint)
                    .frame(width: 2.5, height: barHeight(for: idx))
            }
        }
        .tint(.blue.opacity(0.7))
        .animation(.easeOut(duration: 0.1), value: history)
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(newLevel)
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 2
        let maxExtra: CGFloat = 16
        return base + maxExtra * CGFloat(history[index])
    }
}
