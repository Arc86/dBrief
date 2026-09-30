import AppKit
import AVFoundation
import CoreText
import SwiftUI
import Testing
@testable import dBrief

@Suite("Viewer native visual snapshots", .serialized)
struct ViewerNativeVisualTests {
    @Test(
        "Captures the native viewer controls in four modes with Non-neon on and off",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_VIEWER_SNAPSHOT_DIR to render opt-in native PNG captures."
        )
    )
    @MainActor
    func capturesAppearanceVariants() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] else {
            return
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        try Self.registerSourceOpenDyslexicFonts()

        for mode in ViewerAppearanceMode.allCases {
            for nonNeon in [false, true] {
                let preferences = ViewerAppearancePreferences(
                    mode: mode,
                    sourceAccentHex: "#7054D9",
                    readingFont: .openDyslexic,
                    density: .comfortable,
                    fontSize: 16,
                    showSpeakerNames: true
                )
                let palette = ViewerThemeResolver.resolve(
                    mode: mode,
                    sourceHex: preferences.sourceAccentHex,
                    nonNeon: nonNeon
                )
                let root = ViewerNativeVisualFixture(
                    mode: mode,
                    preferences: preferences,
                    palette: palette,
                    nonNeon: nonNeon
                )
                let imageURL = outputDirectory.appendingPathComponent(
                    "viewer-native-\(mode.rawValue)-\(nonNeon ? "non-neon" : "neon").png"
                )
                try await Self.capture(root, title: "Viewer QA — \(mode.rawValue)", to: imageURL)
            }
        }
    }

    @Test(
        "Captures the shared document header at narrow, standard, and wide content widths",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_VIEWER_SNAPSHOT_DIR to render opt-in native PNG captures."
        )
    )
    @MainActor
    func capturesHeaderAcrossDocumentModesAndWidths() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] else {
            return
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let appearance: ViewerAppearanceMode = .light
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

        for width in [CGFloat(430), CGFloat(850), CGFloat(1400)] {
            for documentMode in ViewerDocumentMode.allCases {
                let root = ViewerHeaderNativeFixture(
                    width: width,
                    documentMode: documentMode,
                    preferences: preferences,
                    palette: palette
                )
                let imageURL = outputDirectory.appendingPathComponent(
                    "viewer-header-\(documentMode.rawValue)-\(Int(width)).png"
                )
                try await Self.capture(
                    root,
                    title: "Viewer header — \(documentMode.displayName) — \(Int(width))pt",
                    size: CGSize(width: width, height: 600),
                    to: imageURL
                )
            }
        }
    }

    @Test(
        "Captures the real analysis panels and retryable editor state in both paper appearances",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_VIEWER_SNAPSHOT_DIR to render opt-in native PNG captures."
        )
    )
    @MainActor
    func capturesAnalysisPanelsAndEditorError() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] else {
            return
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let longSummary = String(repeating:
            "The team reviewed customer feedback and agreed to keep the migration schedule stable while owners resolve remaining access questions. ",
            count: 80
        )
        #expect(longSummary.split(whereSeparator: { $0.isWhitespace }).count > 1_000)

        let sharedCompletedAction = "[Alice/Bob] to confirm the rollout date"
        var analysis = RecordingInsights(
            summary: longSummary,
            actionItems: [
                "[Alice/Bob] to send the meeting notes to the launch team",
                sharedCompletedAction,
                "[Alice] to draft a customer update before Friday",
                "[Bob] to check the migration dashboard with support",
                "[Casey] to review the final copy",
            ],
            tags: ["customer feedback", "migration", "rollout"],
            sentiment: "Positive",
            generatedTitle: "Quarterly planning and migration readiness",
            markdownPath: nil
        )
        analysis.completedActionItems = [sharedCompletedAction]
        let insights = analysis

        let transcript = RichTranscript(
            segments: [
                RichSegment(start: 0, end: 4.2, text: "Let's start with the migration timeline.",
                            originalText: "Let's start with the migration timeline.", speakerId: "speaker-alice"),
                RichSegment(start: 4.3, end: 9.1, text: "The pilot feedback is positive so far.",
                            originalText: "The pilot feedback is positive so far.", speakerId: "speaker-bob"),
                RichSegment(start: 10.0, end: 13.4, text: "I will send the updated rollout dates.",
                            originalText: "I will send the updated rollout dates.", speakerId: "speaker-alice"),
            ],
            speakerLabels: [
                SpeakerLabel(id: "speaker-alice", displayName: "Alice"),
                SpeakerLabel(id: "speaker-bob", displayName: "Bob"),
            ]
        )

        let recording = Recording(
            date: Date(timeIntervalSince1970: 1_780_000_000),
            fileURL: URL(fileURLWithPath: "/tmp/dbrief-viewer-native-fixture.wav"),
            duration: 2_674,
            fileSize: 48_000,
            meetingTitleDraft: "Quarterly planning and migration readiness",
            finalizedAudioURL: URL(fileURLWithPath: "/tmp/dbrief-viewer-native-fixture.wav")
        )
        recording.generatedTitle = "Quarterly planning and migration readiness"
        recording.participants = ["Alice", "Bob"]
        recording.summary = longSummary
        recording.actionItems = insights.actionItems
        recording.tags = insights.tags
        recording.sentiment = insights.sentiment
        recording.richTranscript = transcript

        for appearance in [ViewerAppearanceMode.paper, .darkPaper] {
            let preferences = ViewerAppearancePreferences(
                mode: appearance,
                sourceAccentHex: "#7054D9",
                readingFont: .georgia,
                density: .comfortable,
                fontSize: 16,
                showSpeakerNames: true
            )
            let palette = ViewerThemeResolver.resolve(
                mode: appearance,
                sourceHex: preferences.sourceAccentHex,
                nonNeon: false
            )

            let summary = SummaryView(
                insights: insights,
                isGenerating: false,
                canGenerate: false,
                isReadOnly: false
            )
            let actions = RecordingActionsView(
                insights: insights,
                owners: ["Alice", "Bob", "Casey"],
                isReadOnly: false,
                onSetActionCompleted: { _, _ in insights }
            )
            let meeting = MeetingInsightsView(
                recording: recording,
                richTranscript: transcript,
                insights: insights,
                isReadOnly: false,
                onPrivacyReceipt: {}
            ) {
                ForEach(transcript.speakerLabels, id: \.id) { speaker in
                    Label(speaker.displayName, systemImage: "person")
                }
            }
            let editor = RecordingAnalysisEditor(
                baseline: insights,
                isReadOnly: false,
                saveError: "Could not save the analysis. Your draft is still here; try again.",
                onSave: { _ in },
                onCancel: {}
            )

            let snapshots: [(String, AnyView)] = [
                ("summary", AnyView(summary)),
                ("actions", AnyView(actions)),
                ("meeting-insights", AnyView(meeting)),
                ("analysis-editor-error", AnyView(editor)),
            ]
            for (name, view) in snapshots {
                let root = ViewerPanelNativeFixture(
                    content: view,
                    preferences: preferences,
                    palette: palette
                )
                let imageURL = outputDirectory.appendingPathComponent(
                    "viewer-panel-\(name)-\(appearance.rawValue).png"
                )
                try await Self.capture(
                    root,
                    title: "Viewer panel — \(name) — \(appearance.displayName)",
                    size: CGSize(width: 920, height: 900),
                    to: imageURL
                )
            }
        }
    }

    @Test(
        "Captures the real waveform speaker timeline and reading paragraph at four appearance modes",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_VIEWER_SNAPSHOT_DIR to render opt-in native PNG captures."
        )
    )
    @MainActor
    func capturesWaveformAndReadingPreferences() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] else {
            return
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        try Self.registerSourceOpenDyslexicFonts()

        let segments = [
            RichSegment(start: 0, end: 1.8, text: "A", originalText: "A", speakerId: "speaker-alice"),
            RichSegment(start: 2.0, end: 4.5, text: "B", originalText: "B", speakerId: "speaker-bob"),
            RichSegment(start: 4.7, end: 6.2, text: "C", originalText: "C", speakerId: "speaker-casey"),
            RichSegment(start: 5.5, end: 7.0, text: "B", originalText: "B", speakerId: "speaker-bob"),
        ]
        let ranges = SpeakerTimeline.normalize(segments, duration: 8)
        let sampleCount = 80
        let speakerIDs = SpeakerTimeline.sampledSpeakerIDs(
            in: ranges,
            duration: 8,
            count: sampleCount
        )
        let samples = (0..<sampleCount).map { index in
            Float(0.16 + 0.78 * abs(sin(Double(index) * 0.41)))
        }
        let readingText = AttributedString(
            "We agreed to publish the revised schedule after each owner confirms the dates. "
                + "The transcript keeps short pauses visible, leaves unassigned time neutral, and avoids "
                + "suggesting a single speaker where turns overlap. The written notes remain selectable "
                + "and use the same paragraph renderer as the recording transcript."
        )

        for mode in ViewerAppearanceMode.allCases {
            let palette = ViewerThemeResolver.resolve(
                mode: mode,
                sourceHex: "#7054D9",
                nonNeon: true
            )
            let root = ViewerPlaybackNativeFixture(
                mode: mode,
                palette: palette,
                samples: samples,
                speakerIDs: speakerIDs,
                readingText: readingText
            )
            let imageURL = outputDirectory.appendingPathComponent(
                "viewer-waveform-reading-\(mode.rawValue).png"
            )
            try await Self.capture(
                root,
                title: "Viewer waveform and reading — \(mode.displayName)",
                size: CGSize(width: 920, height: 2_000),
                to: imageURL
            )
        }
    }

    @Test(
        "Captures the real transcript player bar at narrow and standard window widths",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_VIEWER_SNAPSHOT_DIR to render opt-in native PNG captures."
        )
    )
    @MainActor
    func capturesPlayerBarAtNarrowAndStandardWidths() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] else {
            return
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let audioURL = try Self.makeSilentWAV(duration: 30)
        let player = AudioPlayer()
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: audioURL)
        }

        let mode: ViewerAppearanceMode = .paper
        let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: "#7054D9", nonNeon: true)
        let preferences = ViewerAppearancePreferences(
            mode: mode,
            sourceAccentHex: "#7054D9",
            readingFont: .georgia,
            density: .comfortable,
            fontSize: 16
        )
        let segments = [
            RichSegment(start: 0, end: 8, text: "Alice speaks", originalText: "Alice speaks", speakerId: "speaker-alice"),
            RichSegment(start: 8.5, end: 14, text: "Bob speaks", originalText: "Bob speaks", speakerId: "speaker-bob"),
            RichSegment(start: 13, end: 20, text: "Casey overlaps", originalText: "Casey overlaps", speakerId: "speaker-casey"),
            RichSegment(start: 22, end: 28, text: "Bob returns", originalText: "Bob returns", speakerId: "speaker-bob"),
        ]
        let labels = [
            SpeakerLabel(id: "speaker-alice", displayName: "Alice"),
            SpeakerLabel(id: "speaker-bob", displayName: "Bob"),
            SpeakerLabel(id: "speaker-casey", displayName: "Casey"),
        ]

        for width in [CGFloat(430), CGFloat(920)] {
            let height: CGFloat = width < 500 ? 240 : 170
            let root = ViewerPlayerBarNativeFixture(
                width: width,
                height: height,
                audioURL: audioURL,
                recordingDuration: 30,
                segments: segments,
                speakerLabels: labels,
                player: player,
                mode: mode,
                preferences: preferences,
                palette: palette
            )
            let imageURL = outputDirectory.appendingPathComponent(
                "viewer-player-bar-\(Int(width)).png"
            )
            try await Self.capture(
                root,
                title: "Transcript player — \(Int(width))pt",
                size: CGSize(width: width, height: height),
                settleDuration: .milliseconds(350),
                to: imageURL
            )
        }
    }

    @Test(
        "Captures persisted assistant conversations in four modes with Non-neon on and off",
        .enabled(
            if: ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] != nil,
            "Set DBRIEF_VIEWER_SNAPSHOT_DIR to render opt-in native PNG captures."
        )
    )
    @MainActor
    func capturesPersistedChatAcrossAppearanceVariants() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DBRIEF_VIEWER_SNAPSHOT_DIR"] else {
            return
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = try await TranscriptChatFixtureSupport.makeLoadedFixture()
        defer { fixture.removeFiles() }
        fixture.service.draftInput = "Keep this unsent question for the next turn."

        for mode in ViewerAppearanceMode.allCases {
            for nonNeon in [false, true] {
                let preferences = ViewerAppearancePreferences(
                    mode: mode,
                    sourceAccentHex: "#7054D9",
                    readingFont: .systemDefault,
                    density: .comfortable,
                    fontSize: 16
                )
                let palette = ViewerThemeResolver.resolve(
                    mode: mode,
                    sourceHex: preferences.sourceAccentHex,
                    nonNeon: nonNeon
                )
                let root = VStack(spacing: 0) {
                    HStack {
                        Text("Assistant")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.heading.color)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    Rectangle().fill(palette.divider.color).frame(height: 1)
                    TranscriptChatView(chatService: fixture.service)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 374, height: 760)
                .background(palette.surface.color)
                .environment(\.viewerPalette, palette)
                .environment(\.viewerReading, preferences)
                .environment(\.viewerMode, mode)
                .environment(\.viewerNonNeon, nonNeon)
                .environment(\.calmAppearance, nonNeon)
                .preferredColorScheme(mode.isDark ? .dark : .light)

                let imageURL = outputDirectory.appendingPathComponent(
                    "viewer-chat-\(mode.rawValue)-\(nonNeon ? "non-neon" : "neon").png"
                )
                try await Self.capture(
                    root,
                    title: "Transcript chat — \(mode.displayName) — Non-neon \(nonNeon ? "on" : "off")",
                    size: CGSize(width: 374, height: 760),
                    settleDuration: .milliseconds(180),
                    to: imageURL
                )
            }
        }
    }

    @MainActor
    private static func registerSourceOpenDyslexicFonts() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fontDirectory = repositoryRoot.appendingPathComponent("Sources/dBrief/Resources/Fonts", isDirectory: true)
        let fontURLs = try FileManager.default.contentsOfDirectory(
            at: fontDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "otf" }
        #expect(!fontURLs.isEmpty, "The source Fonts directory should contain native OpenType assets.")

        var foundOpenDyslexic = false
        for fontURL in fontURLs {
            _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor] ?? []
            let familyNames = descriptors.compactMap {
                CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
            }
            foundOpenDyslexic = foundOpenDyslexic || familyNames.contains("OpenDyslexic")
        }
        #expect(foundOpenDyslexic, "The packaged source font assets should include the OpenDyslexic family.")

        let font = CTFontCreateWithName("OpenDyslexic-Regular" as CFString, 16, nil)
        #expect((CTFontCopyFamilyName(font) as String) == "OpenDyslexic")
    }

    @MainActor
    private static func makeSilentWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-player-snapshot-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frameCount = Int(format.sampleRate * duration)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channelData = try #require(buffer.floatChannelData)
        channelData[0].initialize(repeating: 0, count: frameCount)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @MainActor
    private static func capture<Content: View>(
        _ root: Content,
        title: String,
        size: CGSize = CGSize(width: 520, height: 620),
        settleDuration: Duration = .milliseconds(100),
        to url: URL
    ) async throws {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settleDuration)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        try writePNG(from: host, to: url)
    }

    @MainActor
    private static func writePNG(from view: NSView, to url: URL) throws {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.viewHasNoRenderableSize
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
            throw SnapshotError.pngEncodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private enum SnapshotError: Error {
        case viewHasNoRenderableSize
        case pngEncodingFailed
    }
}

@MainActor
private struct ViewerNativeVisualFixture: View {
    let mode: ViewerAppearanceMode
    let preferences: ViewerAppearancePreferences
    let palette: ViewerPalette
    let nonNeon: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                ViewerSparkle(size: 20)
                Text("Ask dBrief AI")
                    .font(.system(size: 14, weight: .semibold))
            }
                .foregroundStyle(palette.heading.color)

            Button {} label: {
                HStack(spacing: 8) {
                    ViewerSparkle(size: 14)
                    Text("Ask dBrief AI")
                }
            }
            .buttonStyle(ViewerBrandButtonStyle(height: 32))
            .fixedSize()

            ViewerReadingOptions(preferences: .constant(preferences))
        }
        .padding(24)
        .frame(width: 520, height: 620, alignment: .topLeading)
        .background(palette.canvas.color)
        .environment(\.viewerPalette, palette)
        .environment(\.viewerReading, preferences)
        .environment(\.viewerMode, mode)
        .environment(\.viewerNonNeon, nonNeon)
        .preferredColorScheme(mode.isDark ? .dark : .light)
    }
}

@MainActor
private struct ViewerHeaderNativeFixture: View {
    let width: CGFloat
    let documentMode: ViewerDocumentMode
    let preferences: ViewerAppearancePreferences
    let palette: ViewerPalette

    var body: some View {
        VStack(spacing: 0) {
            ViewerHeader(
                title: "Quarterly planning: product direction, customer feedback, and next steps",
                mode: .constant(documentMode),
                readingOptionsPresented: .constant(false),
                readingPreferences: .constant(preferences),
                unfinishedActions: 7,
                assistantOpen: false,
                onToggleAssistant: {},
                onPrivacyReceipt: {},
                onDelete: {}
            ) {
                commands
            }
            .frame(maxWidth: 920)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: width, height: 600, alignment: .top)
        .background(palette.canvas.color)
        .environment(\.viewerPalette, palette)
        .environment(\.viewerReading, preferences)
        .environment(\.viewerMode, preferences.mode ?? .light)
        .environment(\.viewerNonNeon, false)
        .preferredColorScheme(.light)
    }

    private var commands: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                copyAndEditCommands
                processingCommands
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    copyAndEditCommands
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    processingCommands
                }
            }
        }
        .font(.system(size: 12))
        .buttonStyle(ViewerCommandButtonStyle())
        .tint(palette.accentText.color)
    }

    @ViewBuilder
    private var copyAndEditCommands: some View {
        Button {} label: { Label("Copy", systemImage: "doc.on.doc") }
        if documentMode != .transcript {
            Button {} label: { Label("Edit", systemImage: "pencil") }
        }
    }

    @ViewBuilder
    private var processingCommands: some View {
        Button {} label: { Label("Re-process", systemImage: "arrow.clockwise") }
        if documentMode == .summary {
            Button {} label: { Label("Spoken Summary", systemImage: "waveform") }
        }
    }
}

@MainActor
private struct ViewerPanelNativeFixture: View {
    let content: AnyView
    let preferences: ViewerAppearancePreferences
    let palette: ViewerPalette

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(width: 920, height: 900, alignment: .topLeading)
            .background(palette.canvas.color)
            .environment(\.viewerPalette, palette)
            .environment(\.viewerReading, preferences)
            .environment(\.viewerMode, preferences.mode ?? .light)
            .environment(\.viewerNonNeon, false)
            .preferredColorScheme(preferences.mode?.isDark == true ? .dark : .light)
    }
}

@MainActor
private struct ViewerPlaybackNativeFixture: View {
    let mode: ViewerAppearanceMode
    let palette: ViewerPalette
    let samples: [Float]
    let speakerIDs: [String?]
    let readingText: AttributedString

    private var compactReading: ViewerAppearancePreferences {
        ViewerAppearancePreferences(
            mode: mode,
            sourceAccentHex: "#7054D9",
            readingFont: .systemDefault,
            density: .compact,
            fontSize: 12
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Audio and transcript")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.heading.color)

            VStack(alignment: .leading, spacing: 12) {
                Text("Speaker timeline — gaps and overlap remain neutral")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                SpeakerTimelineBar(
                    runs: SpeakerTimelineBarLayout.runs(sampledIDs: speakerIDs),
                    colors: Dictionary(uniqueKeysWithValues: Set(speakerIDs.compactMap { $0 })
                        .map { ($0, ViewerSpeakerPalette.color(for: $0, mode: mode).color) }),
                    playbackFraction: 0.38,
                    palette: palette,
                    mode: mode,
                    isSeekEnabled: true,
                    onSeek: { _ in }
                )
                .frame(height: 46)
                HStack(spacing: 18) {
                    legend("Alice", speakerID: "speaker-alice")
                    legend("Bob", speakerID: "speaker-bob")
                    legend("Casey", speakerID: "speaker-casey")
                    HStack(spacing: 6) {
                        Circle().fill(ViewerSpeakerPalette.color(for: nil, mode: mode).color)
                            .frame(width: 10, height: 10)
                        Text("Gap / overlap")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary.color)
            }
            .padding(16)
            .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 12))

            Text("Reading settings — six real transcript paragraph variants")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.heading.color)

            VStack(spacing: 9) {
                readingSample(.systemDefault, .compact, 12)
                readingSample(.openDyslexic, .compact, 12)
                readingSample(.systemDefault, .comfortable, 16)
                readingSample(.openDyslexic, .comfortable, 16)
                readingSample(.systemDefault, .spacious, 24)
                readingSample(.openDyslexic, .spacious, 24)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 920, height: 2_000, alignment: .topLeading)
        .background(palette.canvas.color)
        .environment(\.viewerPalette, palette)
        .environment(\.viewerReading, compactReading)
        .environment(\.viewerMode, mode)
        .environment(\.viewerNonNeon, true)
        .preferredColorScheme(mode.isDark ? .dark : .light)
    }

    private func legend(_ title: String, speakerID: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ViewerSpeakerPalette.color(for: speakerID, mode: mode).color)
                .frame(width: 10, height: 10)
            Text(title)
        }
    }

    private func readingSample(
        _ font: ViewerReadingFont,
        _ density: ViewerDensity,
        _ size: Int
    ) -> some View {
        let preferences = ViewerAppearancePreferences(
            mode: mode,
            sourceAccentHex: "#7054D9",
            readingFont: font,
            density: density,
            fontSize: size
        )

        return VStack(alignment: .leading, spacing: CGFloat(density.speakerHeaderGap)) {
            HStack {
                Text("\(size) pt · \(font.displayName) · \(density.displayName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondary.color)
                Spacer()
            }
            ViewerReadingParagraph(text: readingText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(
            top: CGFloat(density.rowVerticalPadding),
            leading: 16,
            bottom: CGFloat(density.rowVerticalPadding),
            trailing: 16
        ))
        .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.viewerPalette, palette)
        .environment(\.viewerReading, preferences)
        .environment(\.viewerMode, mode)
        .environment(\.viewerNonNeon, true)
    }
}

@MainActor
private struct ViewerPlayerBarNativeFixture: View {
    let width: CGFloat
    let height: CGFloat
    let audioURL: URL
    let recordingDuration: TimeInterval
    let segments: [RichSegment]
    let speakerLabels: [SpeakerLabel]
    let player: AudioPlayer
    let mode: ViewerAppearanceMode
    let preferences: ViewerAppearancePreferences
    let palette: ViewerPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio playback and speaker timeline")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            TranscriptPlayerBar(
                audioURL: audioURL,
                recordingDuration: recordingDuration,
                segments: segments,
                speakerLabels: speakerLabels
            )
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(palette.canvas.color)
        .environment(player)
        .environment(\.viewerPalette, palette)
        .environment(\.viewerReading, preferences)
        .environment(\.viewerMode, mode)
        .environment(\.viewerNonNeon, true)
        .preferredColorScheme(mode.isDark ? .dark : .light)
    }
}
