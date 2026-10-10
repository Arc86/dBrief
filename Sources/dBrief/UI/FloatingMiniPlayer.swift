import SwiftUI
import AppKit
import OSLog

/// Manages a small floating window that shows recording status.
@MainActor
@Observable
final class FloatingMiniPlayerController {
    private static let panelWidth: CGFloat = 298
    private static let screenMargin: CGFloat = 12

    private var window: NSPanel?
    private var appState: AppState?
    private var recordingManager: RecordingManager?
    private var appSettings: AppSettings?

    func setUp(appState: AppState, recordingManager: RecordingManager, appSettings: AppSettings) {
        self.appState = appState
        self.recordingManager = recordingManager
        self.appSettings = appSettings
    }

    func show() {
        guard window == nil, let appState, let recordingManager else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0),
            // Borderless: a titled panel reserves an invisible title bar and macOS
            // keeps titled windows below the menu bar, so it couldn't reach the top.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window shadow follows the rounded card's alpha.
        panel.hasShadow = true

        let content = MiniPlayerView()
            .environment(appState)
            .environment(recordingManager)
            .environment(self)
            .environment(\.calmAppearance, appSettings?.reduceNeon ?? false)
            .modifier(AppAppearanceScope(settings: appSettings))

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
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            header
            if !controller.isCollapsed {
                VStack(spacing: 10) {
                    MenuPanelLevelBars(level: appState.peakLevel, active: appState.isRecording, height: 26)
                        .overlay { MiniPlayerDragArea() }

                    // Transient note when the input device / echo cancellation auto-switches.
                    if let note = appState.recordingStatusNote {
                        Label(note, systemImage: "arrow.triangle.2.circlepath")
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.secondary.color)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    HStack(spacing: 8) {
                        if appState.isRecording {
                            Button {
                                recordingManager.pauseRecording()
                            } label: {
                                Label("Pause", systemImage: "pause")
                            }
                            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30))
                        } else if appState.isPaused {
                            Button {
                                do {
                                    try recordingManager.resumeRecording()
                                } catch {
                                    Logger.recording.error("Failed to resume recording: \(error)")
                                }
                            } label: {
                                Label("Resume", systemImage: "play")
                            }
                            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30))
                        }

                        Button {
                            Task { await recordingManager.stopRecording() }
                        } label: {
                            Label("Stop", systemImage: "stop")
                        }
                        .buttonStyle(MenuPanelButtonStyle(kind: .danger, height: 30))
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 298)
        .background(palette.surface.color, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(palette.divider.color, lineWidth: 1).allowsHitTesting(false) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                BrandBarsMark(height: 20)
                Text("dBrief")
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Spacer(minLength: 4)
                MenuPanelStatusDot(tone: appState.isRecording ? .danger : .warning, pulse: appState.isRecording)
                Text(appState.isRecording ? "Recording" : "Paused")
                    .uiFont(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.heading.color)
                Text(formattedDuration)
                    .uiFont(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.heading.color)
            }
            .overlay { MiniPlayerDragArea() }
            .help("Drag to move recording controls")

            Button {
                controller.toggleCollapse()
            } label: {
                Image(systemName: controller.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.text.color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isCollapsed ? "Expand recording controls" : "Collapse recording controls")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 13)
        .background(palette.canvas.color)
        .overlay(alignment: .bottom) {
            if !controller.isCollapsed { MenuPanelHairline() }
        }
    }

    private var formattedDuration: String { appState.recordingDuration.formattedDuration }
}

/// Start dragging explicitly: SwiftUI's hit testing can prevent the panel's
/// `isMovableByWindowBackground` fallback from receiving mouse events.
/// Only cover noninteractive content so recording buttons retain their clicks.
private struct MiniPlayerDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
