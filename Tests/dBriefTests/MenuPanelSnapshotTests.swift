import AppKit
import SwiftUI
import Testing
@testable import dBrief

/// Renders the menu bar panel in its main states and all four appearance modes to
/// PNGs for side-by-side comparison with the Pen "Signature" frames. Opt-in:
/// `DBRIEF_MENU_SNAPSHOT_DIR=/some/dir swift test --filter MenuPanelSnapshotTests`.
@Suite("Menu panel renders", .serialized) @MainActor
struct MenuPanelSnapshotTests {
    nonisolated private static let directory = ProcessInfo.processInfo.environment["DBRIEF_MENU_SNAPSHOT_DIR"]

    @Test(.enabled(if: directory != nil))
    func rendersEveryStateInEveryMode() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        let oldOnboarding = settings.hasCompletedOnboarding
        let oldFolder = settings.recordingFolderURL
        settings.hasCompletedOnboarding = true
        settings.recordingFolderURL = root
        defer {
            settings.hasCompletedOnboarding = oldOnboarding
            settings.recordingFolderURL = oldFolder
        }

        let modes = (ProcessInfo.processInfo.environment["DBRIEF_MENU_SNAPSHOT_MODES"] ?? "light,dark,paper,darkPaper")
            .split(separator: ",").compactMap { ViewerAppearanceMode(rawValue: String($0)) }
        let only = ProcessInfo.processInfo.environment["DBRIEF_MENU_SNAPSHOT_STATES"]?.split(separator: ",").map(String.init)

        for (name, configure, fixture) in Self.states(root: root) where only == nil || only!.contains(name) {
            for mode in modes {
                let state = AppState()
                let manager = RecordingManager(appState: state, appSettings: settings,
                    transcriptStore: TranscriptStore(), insightsStore: InsightsStore(),
                    voiceLibraryStore: VoiceLibraryStore(url: root.appendingPathComponent("voices.json")),
                    modelPerformanceStore: ModelPerformanceStore(url: root.appendingPathComponent("performance.json")),
                    processingJobStore: ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")),
                    microsoftAuthService: MicrosoftAuthService(),
                    reprocessingStore: ReprocessingStore(root: root.appendingPathComponent("attempts")),
                    queueScheduleStore: QueueScheduleStore(url: root.appendingPathComponent("schedule.json")),
                    integrationDeliveryStore: IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries")))
                manager.reprocessingRecoveryReady = true
                configure(state)
                let content: AnyView = fixture.map { make in
                    AnyView(make().padding(16).frame(width: MenuBarView.panelWidth))
                } ?? AnyView(MenuBarView())
                try await render(content
                    .environment(state)
                    .environment(settings)
                    .environment(manager)
                    .environment(AudioPlayer())
                    .environment(MicrosoftAuthService()),
                    mode: mode, to: output.appendingPathComponent("\(name)-\(mode.rawValue).png"))
            }
        }
    }

    /// (name, AppState setup, optional stand-alone fixture rendered instead of the whole panel)
    private static func states(root: URL) -> [(String, (AppState) -> Void, (() -> AnyView)?)] {
        let audio = root.appendingPathComponent("2026-10-05_1000_HVA VU Mailen.m4a")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        func recording() -> Recording {
            Recording(fileURL: audio, duration: 11, fileSize: 6_800_000, meetingTitleDraft: "HVA / VU Mailen", finalizedAudioURL: audio)
        }
        return [
            ("03-ready", { _ in }, nil),
            ("06-video-url", { _ in }, { AnyView(YouTubeURLInputView(isVisible: .constant(true))) }),
            ("04-row-actions", { _ in }, { AnyView(RecordingListRow(title: "Kort Fragment Zonder Inhoud", expanded: true, toggle: {}) {
                RecordingListPlayButton(isPlaying: false, title: "Kort Fragment") {}
            } metadata: {
                HStack(spacing: 6) {
                    Text("Yesterday 1:52 PM · 0:03")
                    RecordingListStatus(title: "Analyzed", systemImage: "checkmark.circle", tint: .green)
                }
            } actions: {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        RecordingListAction(title: "Copy summary", systemImage: "doc.on.doc", style: .tile) {}
                        RecordingListAction(title: "Show in Finder", systemImage: "folder", style: .tile) {}
                        RecordingListAction(title: "Reprocess", systemImage: "arrow.trianglehead.2.clockwise", style: .tile) {}
                    }
                    GridRow {
                        RecordingListAction(title: "Transcript", systemImage: "doc.text", style: .tile) {}.disabled(true)
                        RecordingListAction(title: "Integrations", systemImage: "paperplane", style: .tile) {}
                        RecordingListAction(title: "Delete", systemImage: "trash", destructive: true, style: .tile) {}
                    }
                }
            }) }),
            ("05-queue", { _ in }, { AnyView(ProcessingQueueView(expanded: .constant(true))) }),
            ("07-recording", { state in
                state.recordingState = .recording
                state.recordingDuration = 9
                state.peakLevel = 0.5
                state.activeMicrophoneName = "MacBook Pro Microphone"
            }, nil),
            ("08-completed", { state in
                state.currentRecording = recording()
                state.showPostRecordingSheet = true
            }, nil),
            ("11-processing", { state in
                state.processingJob = ProcessingJob(recording: recording())
                state.processingRecording = recording()
                state.processingSteps = [
                    ProcessingStep(name: "Finalizing audio", status: .completed),
                    ProcessingStep(name: "Identifying speakers", status: .completed),
                    ProcessingStep(name: "Generating summary", status: .inProgress),
                    ProcessingStep(name: "Extracting action items", status: .pending),
                    ProcessingStep(name: "Analyzing tags & sentiment", status: .pending),
                ]
            }, nil),
            ("12-brief", { state in
                var done = recording()
                done.summary = "Dit was een korte testopname zonder inhoudelijke vergadering; er is enkel geverifieerd dat de opname werkt."
                done.actionItems = ["Jesper: check the export folder"]
                done.tags = ["test", "recording"]
                state.processingRecording = done
                state.processingSteps = [
                    ProcessingStep(name: "Finalizing audio", status: .completed),
                    ProcessingStep(name: "Generating summary", status: .completed),
                ]
            }, nil),
        ]
    }

    private func render<V: View>(_ view: V, mode: ViewerAppearanceMode, to url: URL) async throws {
        let typography = AppTypographyPreferences()
        let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: "#1268F5", nonNeon: false)
        let scheme: ColorScheme = mode.isDark ? .dark : .light
        let host = NSHostingView(rootView: view
            .background(palette.surface.color)
            .environment(\.uiTypography, typography)
            .environment(\.font, AppFontStyle.body.resolve(using: typography))
            .environment(\.viewerPalette, palette)
            .environment(\.viewerMode, mode)
            .environment(\.menuPanelPalette, MenuPanelPalette.resolve(mode: mode, base: palette))
            .environment(\.colorScheme, scheme)
            .buttonStyle(.typographyBordered).menuStyle(.button)
            .tint(palette.primary.color)
            .fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuBarView.panelWidth, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let size = host.fittingSize
        window.setContentSize(NSSize(width: MenuBarView.panelWidth, height: size.height))
        host.frame = NSRect(origin: .zero, size: NSSize(width: MenuBarView.panelWidth, height: size.height))
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }
}
