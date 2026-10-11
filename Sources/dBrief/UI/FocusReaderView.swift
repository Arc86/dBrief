import AppKit
import SwiftUI

/// Full-screen, distraction-free reading of one recording's notes or transcript.
/// It opens in its own window, so leaving it (Esc, the close button or ⇧⌘F)
/// returns to the viewer exactly as it was.
struct FocusReaderView: View {
    @Environment(FocusReaderStore.self) private var store
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var controlsFocused: Bool

    static let windowID = "focus-reader"

    var body: some View {
        ZStack(alignment: .top) {
            palette.canvas.color.ignoresSafeArea()
            if let content = store.content, let page = content.pages.contains(store.page) ? store.page : content.initialPage {
                switch page {
                case .notes:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            header(content)
                            notes(content)
                        }
                        .modifier(ReadingColumn())
                        .padding(.top, 88)
                        .padding(.bottom, 120)
                    }
                    .scrollIndicators(.automatic)
                case .transcript:
                    transcript(content)
                }
            } else {
                ContentUnavailableView("Nothing to read yet", systemImage: "doc.text",
                                       description: Text("This recording has no notes or transcript yet."))
            }
            controls
        }
        .background(FocusReaderWindowBridge(background: NSColor(palette.canvas.color)))
        .onContinuousHover { _ in revealControls() }
        .onExitCommand(perform: close)
        .onAppear(perform: revealControls)
        .onDisappear { hideTask?.cancel() }
        .focusedSceneValue(\.recordingViewer, viewerActions)
        .background {
            // ⌘+ / ⌘− adjust the shared reading size.
            Button("Larger Text") { adjustFontSize(by: 1) }.keyboardShortcut("+", modifiers: .command).hidden()
            Button("Larger Text") { adjustFontSize(by: 1) }.keyboardShortcut("=", modifiers: .command).hidden()
            Button("Smaller Text") { adjustFontSize(by: -1) }.keyboardShortcut("-", modifiers: .command).hidden()
        }
    }

    // MARK: - Content

    private var readingFont: Font { ViewerFonts.font(for: reading, effectiveMode: mode) }
    private var lineSpacing: CGFloat { ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode) }

    private func header(_ content: FocusReaderContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.title)
                .font(.system(size: CGFloat(reading.fontSize) * 2, weight: .bold))
                .foregroundStyle(palette.heading.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(content.subtitle)
                .font(.system(size: CGFloat(reading.fontSize) * 0.85))
                .foregroundStyle(palette.secondary.color)
        }
    }

    @ViewBuilder
    private func notes(_ content: FocusReaderContent) -> some View {
        if let summary = content.summary {
            section("Summary") {
                MarkdownText(summary, readingFont: readingFont)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(palette.text.color)
                    .textSelection(.enabled)
            }
        }
        if !content.actionGroups.isEmpty {
            section("Action items") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(content.actionGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.owner)
                                .font(readingFont.weight(.semibold))
                                .foregroundStyle(palette.heading.color)
                            ForEach(group.items) { item in
                                let done = content.completedActions.contains(item.raw)
                                Label {
                                    Text(item.text)
                                        .font(readingFont)
                                        .strikethrough(done)
                                        .foregroundStyle(done ? palette.secondary.color : palette.text.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(done ? palette.primary.color : palette.secondary.color)
                                }
                                .accessibilityLabel("\(done ? "Done" : "To do"): \(item.text)")
                            }
                        }
                    }
                }
            }
        }
        if !content.tags.isEmpty {
            section("Tags") {
                FlowLayout(spacing: 8) {
                    ForEach(content.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: CGFloat(reading.fontSize) * 0.8, weight: .medium))
                            .foregroundStyle(palette.text.color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(palette.surface.color, in: Capsule())
                            .overlay { Capsule().strokeBorder(palette.divider.color) }
                    }
                }
            }
        }
    }

    /// A `List`, like the viewer's transcript: it recycles rows, where a lazy
    /// stack would keep every selectable row it has shown and run out of memory
    /// on long transcripts.
    private func transcript(_ content: FocusReaderContent) -> some View {
        List {
            header(content)
                .modifier(ReadingColumn())
                .padding(.top, 88)
                .padding(.bottom, 28)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(content.turns, id: \.turn.id) { model in
                TranscriptTurnRow(model: model, onSeek: { _ in }) {
                    Text(model.displayName)
                        .uiFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.color)
                }
                .equatable()
                .modifier(ReadingColumn())
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 120, for: .scrollContent)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: CGFloat(reading.fontSize) * 1.25, weight: .semibold))
                .foregroundStyle(palette.heading.color)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    // MARK: - Controls

    /// Notes/Transcript switch and the exit button. They fade while you read and
    /// return on pointer movement or keyboard focus.
    private var controls: some View {
        HStack(spacing: 12) {
            if let content = store.content, content.pages.count > 1 {
                Picker("Show", selection: Binding(get: { store.page }, set: { store.page = $0 })) {
                    ForEach(content.pages, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .focused($controlsFocused)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondary.color)
            .background(palette.surface.color, in: Circle())
            .help("Exit Focus Reader (Esc)")
            .accessibilityLabel("Exit Focus Reader")
            .focused($controlsFocused)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .opacity(controlsVisible || controlsFocused ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controlsVisible || controlsFocused)
    }

    private func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    /// View ▸ Summary / Transcript (⌘1 / ⌘2) switch pages here; ⇧⌘F leaves.
    private var viewerActions: RecordingViewerActions? {
        guard let content = store.content else { return nil }
        let modes: [ViewerDocumentMode] = content.pages.map { $0 == .notes ? .summary : .transcript }
        return RecordingViewerActions(
            mode: store.page == .notes ? .summary : .transcript, availableModes: modes,
            selectMode: { mode in store.page = mode == .summary ? .notes : .transcript },
            copy: nil, isPlaying: false, togglePlayback: nil, assistantOpen: false, toggleAssistant: nil,
            reprocess: nil, hasTranscript: !content.turns.isEmpty, revealInFinder: nil, delete: nil,
            focusReader: close)
    }

    private func adjustFontSize(by step: Int) {
        appSettings.viewerAppearance.fontSize += step
    }

    private func close() {
        dismissWindow(id: Self.windowID)
    }
}

/// The centred reading measure shared by both pages.
private struct ReadingColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
    }
}

/// Puts the reader window into full screen once, paints its background, and
/// scrolls the reading column from the keyboard (Space, Page Up/Down, arrows,
/// Home/End) wherever focus is.
private struct FocusReaderWindowBridge: NSViewRepresentable {
    let background: NSColor

    func makeNSView(context: Context) -> BridgeView { BridgeView(background: background) }
    func updateNSView(_ view: BridgeView, context: Context) { view.window?.backgroundColor = background }
    static func dismantleNSView(_ view: BridgeView, coordinator: ()) { view.removeMonitor() }

    final class BridgeView: NSView {
        let background: NSColor
        private var monitor: Any?
        private var enteredFullScreen = false

        init(background: NSColor) {
            self.background = background
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return removeMonitor() }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = background
            window.collectionBehavior.insert(.fullScreenPrimary)
            if !enteredFullScreen, !window.styleMask.contains(.fullScreen) {
                enteredFullScreen = true
                DispatchQueue.main.async { window.toggleFullScreen(nil) }
            }
            installMonitor()
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !TextInputFocus.isActive, self.scroll(for: event, in: window) else { return event }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Handles a scrolling key; false lets every other key through.
        private func scroll(for event: NSEvent, in window: NSWindow) -> Bool {
            guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                  let scrollView = Self.largestScrollView(in: window.contentView) else { return false }
            let clip = scrollView.contentView
            let page = max(clip.bounds.height - 60, 40)
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let y = clip.bounds.origin.y
            let shift = event.modifierFlags.contains(.shift)
            let target: CGFloat
            switch event.keyCode {
            case 49: target = shift ? y - page : y + page          // Space
            case 121: target = y + page                            // Page Down
            case 116: target = y - page                            // Page Up
            case 125: target = y + 48                              // Down
            case 126: target = y - 48                              // Up
            case 119: target = maxY                                // End
            case 115: target = 0                                   // Home
            default: return false
            }
            // SwiftUI scroll views are flipped: larger y is further down.
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, target), maxY)))
            scrollView.reflectScrolledClipView(clip)
            return true
        }

        private static func largestScrollView(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            var best = view as? NSScrollView
            for subview in view.subviews {
                if let candidate = largestScrollView(in: subview),
                   candidate.frame.height * candidate.frame.width > (best.map { $0.frame.height * $0.frame.width } ?? 0) {
                    best = candidate
                }
            }
            return best
        }
    }
}
