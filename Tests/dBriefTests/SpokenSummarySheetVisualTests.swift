import AppKit
import SwiftUI
import Testing
@testable import dBrief

/// Opt-in PNG captures of the spoken summary sheet's phases in every
/// appearance mode, for visual review against the transcript viewer.
@Suite("Spoken summary sheet visual snapshots", .serialized)
struct SpokenSummarySheetVisualTests {
    @Test(
        "Captures the spoken summary sheet in four modes and four phases",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_SPOKEN_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_SPOKEN_SNAPSHOT_DIR to render opt-in native PNG captures."
        )
    )
    @MainActor
    func capturesPhases() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DBRIEF_SPOKEN_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let phases: [(String, SpokenSummaryService.Phase)] = [
            ("script", .rewriting),
            ("voice", .preparingVoice(progress: 0.42)),
            ("ready", .ready(audioURL: URL(fileURLWithPath: "/tmp/dbrief-spoken.wav"), script: "")),
            ("failed", .failed(message: "The on-device voice model could not be loaded. Check free disk space, then try again.")),
        ]
        for mode in ViewerAppearanceMode.allCases {
            let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: "#1268F5", nonNeon: false)
            for (name, phase) in phases {
                let root = SpokenSummaryPlayerView(
                    phase: phase, isSaved: false,
                    recordingTitle: "Quarterly planning and customer rollout review",
                    audioPlayer: AudioPlayer(),
                    onSave: {}, onClose: {}, onRetry: {}
                )
                .fixedSize()
                .environment(\.viewerPalette, palette)
                .environment(\.viewerMode, mode)
                try await Self.capture(root, dark: mode.isDark,
                                       to: directory.appendingPathComponent("spoken-\(name)-\(mode.rawValue).png"))
            }
        }
    }

    @MainActor
    private static func capture<Content: View>(_ root: Content, dark: Bool, to url: URL) async throws {
        let host = NSHostingView(rootView: root)
        host.setFrameSize(host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
    }
}
