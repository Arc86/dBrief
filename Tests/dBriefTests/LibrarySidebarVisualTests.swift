import AppKit
import SwiftUI
import Testing
@testable import dBrief

/// Opt-in PNG captures of the recording library sidebar in every appearance
/// mode and its list, empty, error, loading and work states, for visual review.
@Suite("Library sidebar visual snapshots", .serialized)
struct LibrarySidebarVisualTests {
    enum Scenario: String, CaseIterable {
        case list, empty, error, loading, work
    }

    @Test(
        "Captures the library sidebar in four modes and five states",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_LIBRARY_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_LIBRARY_SNAPSHOT_DIR to render opt-in native PNG captures."
        )
    )
    @MainActor
    func capturesSidebarStates() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DBRIEF_LIBRARY_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        for mode in ViewerAppearanceMode.allCases {
            for scenario in Scenario.allCases {
                let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: "#1268F5", nonNeon: false)
                let root = LibrarySidebarFixture(scenario: scenario, palette: palette)
                    .frame(width: 300, height: 820)
                    .environment(\.viewerPalette, palette)
                    .environment(\.viewerMode, mode)
                let url = directory.appendingPathComponent("library-\(scenario.rawValue)-\(mode.rawValue).png")
                try await Self.capture(root, dark: mode.isDark, size: CGSize(width: 300, height: 820), to: url)
            }
        }
    }

    @MainActor
    private static func capture<Content: View>(_ root: Content, dark: Bool, size: CGSize, to url: URL) async throws {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
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

@MainActor
private struct LibrarySidebarFixture: View {
    let scenario: LibrarySidebarVisualTests.Scenario
    let palette: ViewerPalette

    @State private var searchText = ""
    @State private var selectedView: LibrarySmartView = .all
    @State private var statusFilter: LibraryRecordingStatus?

    private static let now = Date()

    private static func item(
        _ index: Int, title: String, daysAgo: Double, minutes: Double, status: LibraryRecordingStatus?
    ) -> RecordingBrowserItem {
        var item = RecordingBrowserItem(
            url: URL(fileURLWithPath: "/tmp/dbrief-library-\(index).m4a"),
            name: "2026-10-0\(index)_1015_meeting",
            date: now.addingTimeInterval(-daysAgo * 86_400),
            size: 48_000,
            duration: minutes * 60,
            hasTranscript: status == .done,
            hasRichTranscript: status == .done
        )
        item.generatedTitle = title
        item.libraryStatus = status
        return item
    }

    private let thisWeek: [RecordingBrowserItem] = [
        item(1, title: "Quarterly planning and customer rollout review with the platform team", daysAgo: 0, minutes: 47, status: .done),
        item(2, title: "Design sync", daysAgo: 0, minutes: 12.5, status: .failed),
        item(3, title: "Weekly 1:1 with Sam", daysAgo: 0, minutes: 31, status: .queued),
        item(4, title: "Voice memo", daysAgo: 0, minutes: 2, status: .unprocessed),
    ]
    private let earlier: [RecordingBrowserItem] = [
        item(5, title: "Vendor security review", daysAgo: 12, minutes: 63, status: .done),
        item(6, title: "Hiring debrief", daysAgo: 20, minutes: 28, status: .incomplete),
    ]

    @State private var earlierCollapsed = false

    private let workItems: [LibraryWorkItem] = [
        LibraryWorkItem(id: "w1", recoveryID: UUID(), target: .recovery, title: "Board prep — transcription stopped",
                        audioURL: URL(fileURLWithPath: "/Users/me/Recordings/2026/10/board-prep.m4a"),
                        date: now.addingTimeInterval(-3_600), status: "Transcription failed", failed: true,
                        sourcePath: nil, associatedApp: "Zoom"),
        LibraryWorkItem(id: "w2", recoveryID: UUID(), target: .queue, title: "Customer call",
                        audioURL: nil, date: now.addingTimeInterval(-40 * 86_400), status: "Queued",
                        failed: false, sourcePath: nil, associatedApp: ""),
    ]

    var body: some View {
        ViewerLibrarySidebar(
            searchText: $searchText,
            selectedView: $selectedView,
            statusFilter: $statusFilter,
            isLoading: scenario == .loading,
            isRefreshing: scenario == .loading,
            error: scenario == .error ? "The library database could not be opened. Check that the recordings folder is available." : nil,
            emptyMessage: scenario == .empty ? "No recordings in this folder." : nil,
            isRecordEnabled: true,
            onRecord: {}, onRefresh: {}, onRebuildSearchIndex: {}, onSettings: {}
        ) { statusMenu in
            switch scenario {
            case .list:
                VStack(alignment: .leading, spacing: 2) {
                    LibrarySectionHeader(title: "This week", count: thisWeek.count) { statusMenu }
                    ForEach(thisWeek) { SidebarRecordingRow(item: $0, isSelected: $0 == thisWeek.first, onTap: {}) }
                    LibraryCollapsibleSectionHeader(title: "Earlier", count: earlier.count, collapsed: $earlierCollapsed)
                        .padding(.top, 6)
                    ForEach(earlier) { SidebarRecordingRow(item: $0, isSelected: false, onTap: {}) }
                }
            case .work:
                VStack(alignment: .leading, spacing: 2) {
                    LibrarySectionHeader(title: "Failed jobs", count: workItems.count)
                    ForEach(workItems) { LibraryWorkRow(item: $0, isSelected: $0.id == "w1", onTap: {}) }
                }
            case .empty, .loading:
                LibrarySectionHeader(title: "This week") { statusMenu }
            case .error:
                EmptyView()
            }
        }
    }
}
