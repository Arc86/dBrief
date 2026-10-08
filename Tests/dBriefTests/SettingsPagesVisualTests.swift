import AppKit
import CoreText
import SwiftUI
import Testing
@testable import dBrief

/// Renders the real Settings window, one PNG per page and color scheme, for
/// visual review. Opt in with `DBRIEF_SETTINGS_SNAPSHOT_DIR=<dir> swift test
/// --filter SettingsPagesVisualTests`. Narrow with `DBRIEF_SETTINGS_SNAPSHOT_PAGES=a,b`
/// and render the paper themes with `DBRIEF_SETTINGS_SNAPSHOT_PAPER=1`; set the window
/// width with `DBRIEF_SETTINGS_SNAPSHOT_WIDTH` (default 950). Pages
/// that need the full `AppContext` (Speakers, Import, Profiles) are skipped;
/// Benchmark renders its panel directly over seeded sample timings.
@Suite("Settings pages native renders", .serialized) @MainActor
struct SettingsPagesVisualTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBRIEF_SETTINGS_SNAPSHOT_DIR"] != nil))
    func renderEveryPage() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for url in try FileManager.default.contentsOfDirectory(
            at: project.appendingPathComponent("Sources/dBrief/Resources/Fonts"), includingPropertiesForKeys: nil)
            where url.pathExtension == "otf" {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBRIEF_SETTINGS_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let environment = ProcessInfo.processInfo.environment
        let settings = AppSettings()
        let originalAppearance = settings.viewerAppearance
        defer { settings.viewerAppearance = originalAppearance }
        if environment["DBRIEF_SETTINGS_SNAPSHOT_PAPER"] != nil {
            settings.viewerAppearance.themeMode = .system
            settings.viewerAppearance.lightTheme = .paper
            settings.viewerAppearance.darkTheme = .darkPaper
        }
        let auth = MicrosoftAuthService()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-snapshots-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = RecordingManager(appState: AppState(), appSettings: settings,
            transcriptStore: TranscriptStore(), insightsStore: InsightsStore(),
            voiceLibraryStore: VoiceLibraryStore(url: root.appendingPathComponent("voices.json")),
            modelPerformanceStore: ModelPerformanceStore(url: root.appendingPathComponent("performance.json")),
            processingJobStore: ProcessingJobStore(rootURL: root.appendingPathComponent("jobs")),
            microsoftAuthService: auth)
        let performance = ModelPerformanceStore(url: root.appendingPathComponent("benchmark.json"))
        for (model, audio, time) in [("Apple Speech", 600.0, 6.0), ("Parakeet TDT 0.6B v3 (Multilingual)", 600, 18),
                                     ("Whisper Large V3 Sep24 Turbo (632 MB)", 600, 52)] {
            await performance.append(ModelPerformanceRecord(label: "meeting", transcriptionModel: model,
                audioDuration: audio, transcriptionTime: time, aiModel: "Local CLI", aiTime: 40))
        }
        let skipped: Set<SettingsPage> = [.speakers, .watchedFolders, .profiles]
        let pages = environment["DBRIEF_SETTINGS_SNAPSHOT_PAGES"]
            .map { $0.split(separator: ",").compactMap { SettingsPage(rawValue: String($0)) } }
            ?? SettingsPage.allCases.filter { !skipped.contains($0) }

        for page in pages {
            for scheme in [ColorScheme.light, .dark] {
                let root: AnyView = page == .benchmark
                    ? AnyView(SettingsPageScaffold(page: .benchmark) { ModelPerformanceView(store: performance) }.background(.settingsCanvas))
                    : AnyView(SettingsView(page: page))
                let host = NSHostingView(rootView: root
                    .environment(settings)
                    .environment(manager)
                    .environment(auth)
                    .environment(UpdaterController.shared)
                    .modifier(AppAppearanceScope(settings: settings))
                    .environment(\.colorScheme, scheme))
                let width = Double(environment["DBRIEF_SETTINGS_SNAPSHOT_WIDTH"] ?? "") ?? 950
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                host.sizingOptions = []
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                // cacheDisplay skips the split view's layer-backed columns;
                // capture the composited window instead.
                let output = directory.appendingPathComponent(
                    "settings-\(page.rawValue)-\(scheme == .dark ? "dark" : "light").png")
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", output.path]
                try capture.run()
                capture.waitUntilExit()
                // screencapture fails while the screen is locked; fall back to an
                // offscreen cache, which still covers views outside a split view.
                if !FileManager.default.fileExists(atPath: output.path) {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output)
                }
                window.close()
            }
        }
    }
}
