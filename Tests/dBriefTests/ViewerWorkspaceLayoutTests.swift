import AppKit
import Observation
import SwiftUI
import Testing
@testable import dBrief

@MainActor
@Suite("Whole transcript workspace layout", .serialized)
struct ViewerWorkspaceLayoutTests {
    @Test(
        "Long summary and chat stay inside the native workspace across window sizes and appearances",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_WORKSPACE_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_WORKSPACE_SNAPSHOT_DIR to run the opt-in native workspace layout checks."
        )
    )
    func longDocumentsRemainViewportBounded() async throws {
        _ = NSApplication.shared

        let longSummary = String(repeating:
            "The review covered current customer feedback, remaining access questions, ownership, and the rollout schedule. "
                + "The team agreed to keep the pilot moving while each owner records a clear follow-up and expected date. ",
            count: 120
        )
        #expect(longSummary.split(whereSeparator: { $0.isWhitespace }).count > 2_000)

        let chat = try await WorkspaceChatFixture.makeLongConversation()
        defer { chat.removeFiles() }
        chat.service.draftInput = "Keep this unsent question while the panel is hidden."

        let sizes = [
            WorkspaceSize(name: "compact", width: 1_100, height: 900, assistantWidth: 480),
            WorkspaceSize(name: "standard", width: 1_536, height: 1_024, assistantWidth: 300),
            WorkspaceSize(name: "wide", width: 2_123, height: 1_344, assistantWidth: 300),
        ]
        let snapshotDirectory = ProcessInfo.processInfo.environment["DBRIEF_WORKSPACE_SNAPSHOT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let snapshotDirectory {
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        }

        for appearance in ViewerAppearanceMode.allCases {
            let preferences = ViewerAppearancePreferences(
                mode: appearance,
                sourceAccentHex: "#7054D9",
                readingFont: .systemDefault,
                density: .comfortable,
                fontSize: 16,
                showSpeakerNames: true
            )
            let palette = ViewerThemeResolver.resolve(
                mode: appearance,
                sourceHex: preferences.sourceAccentHex,
                nonNeon: false
            )

            for size in sizes {
                let metrics = WorkspaceBoundsRecorder()
                let model = WorkspaceFixtureModel(
                    insights: RecordingInsights(
                        summary: "A short summary loaded first.",
                        actionItems: [],
                        tags: [],
                        sentiment: "",
                        markdownPath: nil
                    )
                )
                let fixture = ViewerWorkspaceFixture(
                    model: model,
                    chatService: chat.service,
                    preferences: preferences,
                    palette: palette,
                    nonNeon: false,
                    assistantWidth: size.assistantWidth,
                    metrics: metrics
                )
                let host = NSHostingView(rootView: fixture)
                let window = WorkspaceTestWindow(
                    contentRect: NSRect(origin: .zero, size: CGSize(width: size.width, height: size.height)),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "Workspace layout QA — \(size.name) — \(appearance.rawValue)"
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.setContentSize(NSSize(width: size.width, height: size.height))
                window.center()
                window.makeKeyAndOrderFront(nil)
                window.setContentSize(NSSize(width: size.width, height: size.height))
                defer { window.close() }

                try await Self.settle(window)
                Self.expectHostingBounds(host, size: CGSize(width: size.width, height: size.height))
                try Self.expectNativeWindowChrome(window)
                let shortBounds = try Self.requireBounds(metrics.values)
                try Self.expectAnchorsWithinWorkspace(shortBounds, viewport: CGSize(width: size.width, height: size.height))

                // Model the real load path: a short initial state is replaced in-place
                // while the same native window and detail view remain mounted.
                model.insights = RecordingInsights(
                    summary: longSummary,
                    actionItems: ["Alice to confirm the rollout date"],
                    tags: ["planning", "customer feedback"],
                    sentiment: "Positive",
                    markdownPath: nil
                )
                try await Self.settle(window)
                let longBounds = try Self.requireBounds(metrics.values)
                try Self.expectAnchorsWithinWorkspace(longBounds, viewport: CGSize(width: size.width, height: size.height))
                try Self.expectStableOuterAnchors(
                    before: shortBounds,
                    after: longBounds,
                    names: ["workspace-root", "sidebar", "header", "summary", "assistant", "chat"]
                )

                if appearance == .light, size.name == "compact" {
                    let summaryWidth = try #require(longBounds["summary"]).width
                    let chatWidth = try #require(longBounds["chat"]).width
                    let summaryView = try #require(Self.overflowingScrollView(
                        in: host,
                        matchingWidth: summaryWidth
                    ), "The long summary should be hosted in a native scroll view with overflow.")
                    let chatView = try #require(Self.overflowingScrollView(
                        in: host,
                        matchingWidth: chatWidth
                    ), "The long assistant conversation should be hosted in a native scroll view with overflow.")
                    #expect(summaryView !== chatView, "Summary and assistant scrolling must target distinct native scroll views.")

                    let beforeScroll = longBounds
                    #expect(Self.scrollByOnePage(summaryView))
                    #expect(Self.scrollByOnePage(chatView))
                    try await Self.settle(window, passes: 2)
                    let afterScroll = try Self.requireBounds(metrics.values)
                    try Self.expectStableOuterAnchors(
                        before: beforeScroll,
                        after: afterScroll,
                        names: ["workspace-root", "sidebar", "header", "summary", "assistant", "chat"]
                    )

                    // Hiding and reopening the actual assistant panel must not resize
                    // the native workspace or discard its persisted conversation/draft.
                    model.assistantOpen = false
                    try await Self.settle(window)
                    let closedBounds = try Self.requireBounds(
                        metrics.values,
                        required: ["workspace-root", "sidebar", "header", "summary"]
                    )
                    try Self.expectAnchorsWithinWorkspace(closedBounds, viewport: CGSize(width: size.width, height: size.height))
                    try Self.expectStableOuterAnchors(
                        before: afterScroll,
                        after: closedBounds,
                        names: ["workspace-root", "sidebar"]
                    )
                    #expect(closedBounds["assistant"] == nil)
                    #expect(closedBounds["chat"] == nil)
                    model.assistantOpen = true
                    try await Self.settle(window)
                    let reopenedBounds = try Self.requireBounds(metrics.values)
                    try Self.expectAnchorsWithinWorkspace(reopenedBounds, viewport: CGSize(width: size.width, height: size.height))
                    #expect(chat.service.messages.count == 2)
                    #expect(chat.service.draftInput == "Keep this unsent question while the panel is hidden.")
                }

                if let snapshotDirectory {
                    try Self.writePNG(
                        from: host,
                        to: snapshotDirectory.appendingPathComponent(
                            "workspace-\(appearance.rawValue)-\(size.name)-assistant-open.png"
                        )
                    )
                }
            }
        }
    }

    @Test(
        "The empty assistant state also fits a compact native window",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_WORKSPACE_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_WORKSPACE_SNAPSHOT_DIR to run the opt-in native workspace layout checks."
        )
    )
    func emptyAssistantFitsCompactWindow() async throws {
        _ = NSApplication.shared
        let service = WorkspaceChatFixture.makeEmptyService()
        let preferences = ViewerAppearancePreferences(mode: .light)
        let palette = ViewerThemeResolver.resolve(mode: .light, sourceHex: preferences.sourceAccentHex, nonNeon: false)
        let metrics = WorkspaceBoundsRecorder()
        let model = WorkspaceFixtureModel(
            insights: RecordingInsights(summary: "A short summary.", actionItems: [], tags: [], sentiment: "", markdownPath: nil)
        )
        let root = ViewerWorkspaceFixture(
            model: model,
            chatService: service,
            preferences: preferences,
            palette: palette,
            nonNeon: false,
            assistantWidth: 480,
            metrics: metrics
        )
        let host = NSHostingView(rootView: root)
        let window = WorkspaceTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 1_100, height: 900))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 1_100, height: 900))
        try await Self.settle(window)
        Self.expectHostingBounds(host, size: CGSize(width: 1_100, height: 900))
        try Self.expectNativeWindowChrome(window)

        let bounds = try Self.requireBounds(metrics.values)
        try Self.expectAnchorsWithinWorkspace(bounds, viewport: CGSize(width: 1_100, height: 900))
        #expect(service.messages.isEmpty)
        #expect(bounds["assistant"] != nil)
        #expect(bounds["chat"] != nil)
    }

    @Test(
        "Selecting a long recording preserves the library sidebar width",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_WORKSPACE_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_WORKSPACE_SNAPSHOT_DIR to run the opt-in native workspace layout checks."
        )
    )
    func selectingRecordingDoesNotResizeSidebar() async throws {
        _ = NSApplication.shared
        let preferences = ViewerAppearancePreferences(mode: .light)
        let palette = ViewerThemeResolver.resolve(mode: .light, sourceHex: preferences.sourceAccentHex, nonNeon: false)
        let metrics = WorkspaceBoundsRecorder()
        let model = WorkspaceFixtureModel(
            insights: RecordingInsights(summary: "A short summary.", actionItems: [], tags: [], sentiment: "", markdownPath: nil),
            documentLoaded: false
        )
        let root = ViewerWorkspaceFixture(
            model: model,
            chatService: WorkspaceChatFixture.makeEmptyService(),
            preferences: preferences,
            palette: palette,
            nonNeon: false,
            assistantWidth: 300,
            metrics: metrics
        )
        let host = NSHostingView(rootView: root)
        let window = WorkspaceTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_536, height: 1_024),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 1_536, height: 1_024))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 1_536, height: 1_024))
        try await Self.settle(window)
        Self.expectHostingBounds(host, size: CGSize(width: 1_536, height: 1_024))
        try Self.expectNativeWindowChrome(window)

        let emptyBounds = try Self.requireBounds(metrics.values, required: ["workspace-root", "sidebar"])
        let initialSidebar = try #require(emptyBounds["sidebar"])
        #expect(abs(initialSidebar.width - 300) < 2)
        let firstWidth = try #require(metrics.sidebarWidths.first)
        #expect(abs(firstWidth - 300) < 2,
                "The first laid-out sidebar must already have its final width, without a delayed correction; got \(firstWidth).")

        // Selecting a recording replaces the placeholder with the real document
        // composition in the same width-controlled layout and native window.
        model.documentLoaded = true
        try await Self.settle(window)
        let loadedBounds = try Self.requireBounds(metrics.values)
        try Self.expectAnchorsWithinWorkspace(loadedBounds, viewport: CGSize(width: 1_536, height: 1_024))
        let loadedSidebar = try #require(loadedBounds["sidebar"])
        #expect(abs(loadedSidebar.width - initialSidebar.width) < 2,
                "Loading a recording should retain sidebar width; it changed from \(initialSidebar.width) to \(loadedSidebar.width).")

        model.sidebarWidth = 320
        try await Self.settle(window)
        let resizedBounds = try Self.requireBounds(metrics.values)
        let resizedSidebar = try #require(resizedBounds["sidebar"])
        #expect(abs(resizedSidebar.width - 320) < 5,
                "The user-resizable sidebar should move from its wider default to 320 pt; got \(resizedSidebar.width).")

        model.sidebarOpen = false
        try await Self.settle(window, passes: 10)
        #expect(metrics.values["sidebar"] == nil)
        let closedBounds = try Self.requireBounds(metrics.values,
            required: ["workspace-root", "header", "summary", "assistant", "chat"])
        try Self.expectAnchorsWithinWorkspace(closedBounds, viewport: CGSize(width: 1_536, height: 1_024))
        if let outputPath = ProcessInfo.processInfo.environment["DBRIEF_WORKSPACE_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.writePNG(from: host, to: directory.appendingPathComponent("workspace-sidebar-hidden.png"))
        }
        model.sidebarOpen = true
        try await Self.settle(window, passes: 10)
        let restoredBounds = try Self.requireBounds(metrics.values)
        let restoredSidebar = try #require(restoredBounds["sidebar"])
        #expect(abs(restoredSidebar.width - resizedSidebar.width) < 2,
                "The animated sidebar toggle should retain its width after collapse and reopen.")
    }

    private static func requireBounds(
        _ values: [String: CGRect],
        required: [String] = ["workspace-root", "sidebar", "header", "summary", "assistant", "chat"]
    ) throws -> [String: CGRect] {
        for name in required {
            if values[name] == nil {
                Issue.record("Missing native workspace measurement for \(name). Current measurements: \(values)")
            }
        }
        return values
    }

    private static func expectAnchorsWithinWorkspace(_ bounds: [String: CGRect], viewport: CGSize) throws {
        let root = try #require(bounds["workspace-root"])
        #expect(abs(root.width - viewport.width) < 2, "Workspace width should follow the native window content width; got \(root.width), expected \(viewport.width).")
        #expect(abs(root.height - viewport.height) < 2, "Workspace height should follow the native window content height; got \(root.height), expected \(viewport.height).")
        for name in ["sidebar", "header", "summary", "assistant", "chat"] {
            guard let rect = bounds[name] else { continue }
            #expect(rect.minX >= root.minX - 2, "\(name) starts left of the workspace: \(rect) vs \(root).")
            #expect(rect.maxX <= root.maxX + 2, "\(name) extends right of the workspace: \(rect) vs \(root).")
            #expect(rect.minY >= root.minY - 2, "\(name) starts above the workspace: \(rect) vs \(root).")
            #expect(rect.maxY <= root.maxY + 2, "\(name) extends below the workspace: \(rect) vs \(root).")
        }
    }

    private static func expectStableOuterAnchors(
        before: [String: CGRect],
        after: [String: CGRect],
        names: [String]
    ) throws {
        for name in names {
            guard let first = before[name], let second = after[name] else { continue }
            #expect(abs(first.minX - second.minX) < 2, "\(name) moved horizontally: \(first) → \(second).")
            #expect(abs(first.minY - second.minY) < 2, "\(name) moved vertically: \(first) → \(second).")
            #expect(abs(first.height - second.height) < 2, "\(name) height changed: \(first) → \(second).")
            if name != "summary" {
                #expect(abs(first.width - second.width) < 2, "\(name) width changed: \(first) → \(second).")
            }
        }
    }

    private static func overflowingScrollView(in root: NSView, matchingWidth width: CGFloat) -> NSScrollView? {
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        return descendants(of: root)
            .compactMap { $0 as? NSScrollView }
            .filter { scroll in
                guard let document = scroll.documentView else { return false }
                return document.frame.height > scroll.contentView.bounds.height + 80
            }
            .min { abs($0.contentView.bounds.width - width) < abs($1.contentView.bounds.width - width) }
    }

    private static func scrollByOnePage(_ scrollView: NSScrollView) -> Bool {
        guard let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let initialY = clip.bounds.origin.y
        let maximum = max(0, document.frame.height - clip.bounds.height)
        let attempts = [initialY + 180, initialY - 180, maximum, 0]
        for targetY in attempts {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(clip)
            scrollView.layoutSubtreeIfNeeded()
            if abs(clip.bounds.origin.y - initialY) > 2 { return true }
        }
        return false
    }

    private static func settle(_ window: NSWindow, passes: Int = 4) async throws {
        for _ in 0..<passes {
            try await Task.sleep(for: .milliseconds(35))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private static func expectHostingBounds(_ host: NSView, size: CGSize) {
        #expect(abs(host.bounds.width - size.width) < 2,
                "Native host width should match requested test window; got \(host.bounds.width), expected \(size.width).")
        #expect(abs(host.bounds.height - size.height) < 2,
                "Native host height should match requested test window; got \(host.bounds.height), expected \(size.height).")
    }

    private static func expectNativeWindowChrome(_ window: NSWindow) throws {
        #expect(window.toolbar == nil, "The viewer should not create a separate native toolbar row.")
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.isMovableByWindowBackground)

        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(buttonType), "Native titlebar control \(buttonType) should remain present.")
            #expect(!button.isHidden, "Native titlebar control \(buttonType) should remain visible.")
        }

        let contentView = try #require(window.contentView)
        #expect(abs(contentView.frame.width - window.frame.width) < 2,
                "Full-size viewer content should reach both window edges horizontally.")
        #expect(abs(contentView.frame.height - window.frame.height) < 2,
                "Full-size viewer content should extend through the hidden-titlebar area to the native window top; content \(contentView.frame.height), frame \(window.frame.height).")
    }

    private static func writePNG(from view: NSView, to url: URL) throws {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw WorkspaceSnapshotError.noRenderableSize
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
            throw WorkspaceSnapshotError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private enum WorkspaceSnapshotError: Error {
        case noRenderableSize
        case encodingFailed
    }
}

@MainActor
private final class WorkspaceTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private struct WorkspaceSize {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let assistantWidth: CGFloat
}

@MainActor
@Observable
private final class WorkspaceFixtureModel {
    var insights: RecordingInsights?
    var mode: ViewerDocumentMode = .summary
    var assistantOpen = true
    var documentLoaded: Bool
    var sidebarOpen = true
    var sidebarWidth: CGFloat = 300

    init(insights: RecordingInsights?, documentLoaded: Bool = true) {
        self.insights = insights
        self.documentLoaded = documentLoaded
    }
}

@MainActor
private final class WorkspaceBoundsRecorder {
    private(set) var values: [String: CGRect] = [:]
    private(set) var sidebarWidths: [CGFloat] = []
    func update(_ newValues: [String: CGRect]) {
        values = newValues
        if let sidebar = newValues["sidebar"] { sidebarWidths.append(sidebar.width) }
    }
}

private struct WorkspaceBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}

private extension View {
    func trackWorkspaceBounds(_ name: String, enabled: Bool = true) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WorkspaceBoundsPreferenceKey.self,
                    value: enabled ? [name: proxy.frame(in: .named("viewer-workspace-root"))] : [:]
                )
            }
        }
    }
}

@MainActor
private struct ViewerWorkspaceFixture: View {
    @Bindable var model: WorkspaceFixtureModel
    let chatService: TranscriptChatService
    let preferences: ViewerAppearancePreferences
    let palette: ViewerPalette
    let nonNeon: Bool
    let assistantWidth: CGFloat
    let metrics: WorkspaceBoundsRecorder

    @State private var searchText = ""
    @State private var selectedView: LibrarySmartView = .all
    @State private var statusFilter: LibraryRecordingStatus?
    private let items: [RecordingBrowserItem] = (0..<100).map { index in
        RecordingBrowserItem(
            url: URL(fileURLWithPath: "/tmp/dbrief-workspace-row-\(index).wav"),
            name: "2026-09-\(String(format: "%02d", (index % 28) + 1))_1015_planning-review-\(index)",
            date: Date(timeIntervalSince1970: 1_790_000_000 - Double(index * 86_400)),
            size: 48_000,
            duration: 1_420 + Double(index),
            hasTranscript: true,
            hasRichTranscript: true
        )
    }

    private var navigation: some View {
        ViewerLibraryLayout(sidebarOpen: model.sidebarOpen, onToggleSidebar: { model.sidebarOpen.toggle() }, width: $model.sidebarWidth) {
            sidebar.trackWorkspaceBounds("sidebar", enabled: model.sidebarOpen)
        } detail: {
            Group {
                if model.documentLoaded {
                    ViewerDocumentLayout {
                        ViewerHeader(
                            title: "Quarterly planning and customer rollout review",
                            mode: $model.mode,
                            readingOptionsPresented: .constant(false),
                            readingPreferences: .constant(preferences),
                            unfinishedActions: model.insights?.unfinishedActionItems.count ?? 0,
                            assistantOpen: model.assistantOpen,
                            onToggleAssistant: { model.assistantOpen.toggle() },
                            onPrivacyReceipt: {},
                            onDelete: {}
                        ) {
                            HStack(spacing: 8) {
                                Button { } label: { Label("Copy", systemImage: "doc.on.doc") }
                                if model.mode != .transcript {
                                    Button { } label: { Label("Edit", systemImage: "pencil") }
                                }
                                Button { } label: { Label("Re-process", systemImage: "arrow.clockwise") }
                            }
                            .buttonStyle(ViewerCommandButtonStyle())
                            .tint(palette.accentText.color)
                        }
                        .frame(maxWidth: 920)
                        .trackWorkspaceBounds("header")
                    } document: {
                        SummaryView(insights: model.insights, isGenerating: false, canGenerate: false)
                            .trackWorkspaceBounds("summary")
                    } playback: {
                        EmptyView()
                    } assistant: {
                        if model.assistantOpen {
                            ViewerAssistantPanel(onDevice: false, onClose: { model.assistantOpen = false }) {
                                TranscriptChatView(chatService: chatService)
                                    .trackWorkspaceBounds("chat")
                            }
                            .frame(width: assistantWidth)
                            .padding(.vertical, 20)
                            .padding(.trailing, 20)
                            .trackWorkspaceBounds("assistant")
                        }
                    }
                    .background(palette.canvas.color)
                } else {
                    ContentUnavailableView(
                        "Select a Recording",
                        systemImage: "text.bubble",
                        description: Text("Choose a recording to view its transcript."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(palette.canvas.color)
                }
            }
        }
        .background(palette.canvas.color)
        .coordinateSpace(name: "viewer-workspace-root")
        .trackWorkspaceBounds("workspace-root")
        .onPreferenceChange(WorkspaceBoundsPreferenceKey.self) { metrics.update($0) }
    }

    private var sidebar: some View {
        ViewerLibrarySidebar(
            searchText: $searchText,
            selectedView: $selectedView,
            statusFilter: $statusFilter,
            isLoading: false,
            isRefreshing: false,
            error: nil,
            emptyMessage: nil,
            isRecordEnabled: true,
            onRecord: {},
            onRefresh: {},
            onRebuildSearchIndex: {},
            onSettings: {}
        ) { statusMenu in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("This week")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                    Spacer(minLength: 4)
                    statusMenu
                }
                .padding(.leading, 9)
                .padding(.trailing, 3)
                .frame(height: 32)
                ForEach(items) { item in
                    SidebarRecordingRow(item: item, isSelected: item == items.first, onTap: {})
                }
            }
        }
    }

    var body: some View {
        navigation
            .frame(minWidth: 760, minHeight: 480)
            .background(palette.canvas.color)
            .modifier(ViewerWindowChrome())
            .environment(\.viewerPalette, palette)
            .environment(\.viewerReading, preferences)
            .environment(\.viewerMode, preferences.mode ?? .light)
            .environment(\.viewerNonNeon, nonNeon)
            .environment(\.calmAppearance, nonNeon)
            .preferredColorScheme((preferences.mode ?? .light).isDark ? .dark : .light)
    }
}

@MainActor
private struct WorkspaceChatSession {
    let service: TranscriptChatService
    let sidecarURL: URL?

    func removeFiles() {
        if let sidecarURL { try? FileManager.default.removeItem(at: sidecarURL) }
    }
}

@MainActor
private enum WorkspaceChatFixture {
    static func makeLongConversation() async throws -> WorkspaceChatSession {
        let longAnswer = String(repeating:
            "The discussion reviewed the customer rollout, confirmed the current milestone, and recorded a follow-up for the named owner. "
                + "The project team will check the support response, update the decision log, and share the revised schedule after the access review. ",
            count: 75
        )
        #expect(longAnswer.split(whereSeparator: { $0.isWhitespace }).count > 2_000)
        let history = ChatHistory(messages: [
            ChatMessage(role: .user, content: "What did the team agree to do next?"),
            ChatMessage(role: .assistant, content: longAnswer),
        ], engine: "native-workspace-fixture")
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-workspace-chat-\(UUID().uuidString).chat.json")
        let store = ChatStore()
        try await store.save(history, to: sidecarURL)

        let service = TranscriptChatService(
            transcriptText: "The team reviewed the rollout schedule and customer access questions.",
            speakerLabels: [],
            appSettings: makeSettingsWithoutPersistentDefaultMutation(),
            localPlugin: nil
        )
        service.enablePersistence(store: store, url: sidecarURL)
        await service.loadPersisted()
        guard service.messages == history.messages else {
            try? FileManager.default.removeItem(at: sidecarURL)
            throw FixtureError.persistedConversationDidNotLoad
        }
        return WorkspaceChatSession(service: service, sidecarURL: sidecarURL)
    }

    static func makeEmptyService() -> TranscriptChatService {
        TranscriptChatService(
            transcriptText: "The transcript is available for questions.",
            speakerLabels: [],
            appSettings: makeSettingsWithoutPersistentDefaultMutation(),
            localPlugin: nil
        )
    }

    /// AppSettings has one legacy migration that writes `customVocabulary` when
    /// the old prompt exists. Restrict this initializer's lookup to a temporary
    /// volatile argument-domain override and restore the complete domain.
    private static func makeSettingsWithoutPersistentDefaultMutation() -> AppSettings {
        let defaults = UserDefaults.standard
        let originalArgumentDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var isolatedArgumentDomain = originalArgumentDomain
        isolatedArgumentDomain["customVocabulary"] = [String]()
        defaults.setVolatileDomain(isolatedArgumentDomain, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArgumentDomain, forName: UserDefaults.argumentDomain) }
        return AppSettings()
    }

    private enum FixtureError: Error {
        case persistedConversationDidNotLoad
    }
}
