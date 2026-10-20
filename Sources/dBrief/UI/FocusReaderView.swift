import AppKit
import SwiftUI

/// Full-screen, distraction-free reading of one recording's notes or transcript.
/// It opens in its own window, so leaving it (Esc, the close button or ⇧⌘F)
/// returns to the viewer exactly as it was.
struct FocusReaderView: View {
    @Environment(FocusReaderStore.self) private var store
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var viewerReading
    @Environment(\.viewerMode) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var textOptionsShown = false
    @State private var pinchStart: FocusReaderTextSettings?
    @FocusState private var controlsFocused: Bool
    @AppStorage("focusReaderFontSize") private var storedSize = FocusReaderTextSettings.defaultSize
    @AppStorage("focusReaderFont") private var storedFont = ""
    @AppStorage("focusReaderWidth") private var storedWidth = FocusReaderWidth.default.rawValue
    @AppStorage("focusReaderLineHeight") private var storedLineHeight = FocusReaderTextSettings.defaultLineHeight

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
                        .modifier(ReadingColumn(maxWidth: width.maxWidth))
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
        .environment(\.viewerReading, reading)
        // Pinch on the trackpad to resize the text, from the size when the pinch began.
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? textSettings
                pinchStart = start
                apply(start.pinched(by: value.magnification))
            }
            .onEnded { _ in pinchStart = nil })
    }

    // MARK: - Text settings

    private var width: FocusReaderWidth { FocusReaderWidth(rawValue: storedWidth) ?? .default }

    private var textSettings: FocusReaderTextSettings {
        FocusReaderTextSettings(size: storedSize, font: ViewerReadingFont(rawValue: storedFont), lineHeight: storedLineHeight)
    }

    /// The viewer's reading preferences at the reader's own size and font.
    private var reading: ViewerAppearancePreferences { textSettings.applied(to: viewerReading) }

    private func apply(_ settings: FocusReaderTextSettings) {
        storedSize = settings.size
        storedFont = settings.font?.rawValue ?? ""
        storedLineHeight = settings.lineHeight
    }

    private func changeSize(by steps: Int) {
        var settings = textSettings
        if steps > 0 { settings.enlarge() } else { settings.shrink() }
        apply(settings)
    }

    // MARK: - Content

    private var readingFont: Font { ViewerFonts.font(for: reading, effectiveMode: mode) }
    private var lineSpacing: CGFloat { ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode) }

    /// Title, headings and pills in the reader's own font, scaled from its size.
    private func readerFont(scale: CGFloat, bold: Bool = false) -> Font {
        Font(ViewerFonts.nsFont(for: reading, scale: scale, bold: bold, effectiveMode: mode))
    }

    private func header(_ content: FocusReaderContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.title)
                .font(readerFont(scale: 2, bold: true))
                .foregroundStyle(palette.heading.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(content.subtitle)
                .font(readerFont(scale: 0.85))
                .foregroundStyle(palette.secondary.color)
        }
    }

    @ViewBuilder
    private func notes(_ content: FocusReaderContent) -> some View {
        if let summary = content.summary {
            section(String(localized: "Summary")) {
                MarkdownText(summary, readingFont: readingFont)
                    .font(readingFont)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(palette.text.color)
                    .textSelection(.enabled)
            }
        }
        if !content.actionGroups.isEmpty {
            section(String(localized: "Action items")) {
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
                                .accessibilityLabel(done ? "Done: \(item.text)" : "To do: \(item.text)")
                            }
                        }
                    }
                }
            }
        }
        if !content.tags.isEmpty {
            section(String(localized: "Tags")) {
                FlowLayout(spacing: 8) {
                    ForEach(content.tags, id: \.self) { tag in
                        Text(tag)
                            .font(readerFont(scale: 0.8))
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
                .modifier(ReadingColumn(maxWidth: width.maxWidth))
                .padding(.top, 88)
                .padding(.bottom, 28)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(content.turns, id: \.turn.id) { model in
                TranscriptTurnRow(model: model, onSeek: nil) {
                    Text(model.displayName)
                        .uiFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.color)
                }
                .equatable()
                .modifier(ReadingColumn(maxWidth: width.maxWidth))
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
                .font(readerFont(scale: 1.25, bold: true))
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
                // Neutral, like the round buttons: no accent colour to pull the eye.
                HStack(spacing: 2) {
                    ForEach(content.pages, id: \.self) { page in
                        let selected = store.page == page
                        Button { store.page = page } label: {
                            Text(page.title)
                                .uiFont(.system(size: 12, weight: selected ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? palette.heading.color : palette.secondary.color)
                        .background(selected ? palette.canvas.color : .clear, in: Capsule())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .focused($controlsFocused)
                    }
                }
                .padding(2)
                .background(palette.surface.color, in: Capsule())
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Show")
            }
            Spacer()
            Button { textOptionsShown.toggle() } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondary.color)
            .background(palette.surface.color, in: Circle())
            .help("Text size and font")
            .accessibilityLabel("Text size and font")
            .focused($controlsFocused)
            .popover(isPresented: $textOptionsShown, arrowEdge: .bottom) { textOptions }
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
        .opacity(controlsShown ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controlsShown)
    }

    private var controlsShown: Bool { controlsVisible || controlsFocused || textOptionsShown }

    private var textOptions: some View {
        let settings = textSettings
        return VStack(alignment: .leading, spacing: 14) {
            ReadingFontPicker(
                selection: Binding(
                    get: { settings.font },
                    set: { apply(FocusReaderTextSettings(size: settings.size, font: $0,
                                                         lineHeight: settings.lineHeight)) }),
                inheritLabel: "Same as the viewer")
            HStack(spacing: 10) {
                Button { changeSize(by: -1) } label: { Image(systemName: "textformat.size.smaller") }
                    .accessibilityLabel("Smaller text")
                    .disabled(settings.size <= FocusReaderTextSettings.sizeRange.lowerBound)
                Slider(value: Binding(
                    get: { Double(settings.size) },
                    set: { value in var next = settings; next.setSize(Int(value.rounded())); apply(next) }),
                       in: Double(FocusReaderTextSettings.sizeRange.lowerBound)...Double(FocusReaderTextSettings.sizeRange.upperBound),
                       step: Double(FocusReaderTextSettings.step))
                    .frame(width: 180)
                    .accessibilityLabel("Text size")
                    .accessibilityValue("\(settings.size) points")
                Button { changeSize(by: 1) } label: { Image(systemName: "textformat.size.larger") }
                    .accessibilityLabel("Larger text")
                    .disabled(settings.size >= FocusReaderTextSettings.sizeRange.upperBound)
                Text("\(settings.size) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("Line spacing")
                Slider(value: Binding(
                    get: { settings.lineHeight },
                    set: { value in var next = settings; next.setLineHeight((value * 10).rounded() / 10); apply(next) }),
                       in: FocusReaderTextSettings.lineHeightRange, step: 0.1)
                    .frame(width: 180)
                    .accessibilityLabel("Line spacing")
                    .accessibilityValue("\(settings.lineHeight, specifier: "%.1f") times the text size")
                Text("\(settings.lineHeight, specifier: "%.1f")×")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Picker("Width", selection: $storedWidth) {
                ForEach(FocusReaderWidth.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text("Pinch on the trackpad or press ⌘+ / ⌘− to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
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
            focusReader: close, changeTextSize: { changeSize(by: $0) })
    }

    private func close() {
        dismissWindow(id: Self.windowID)
    }
}

/// The centred reading measure shared by both pages.
private struct ReadingColumn: ViewModifier {
    let maxWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth ?? .infinity, alignment: .leading)
            .padding(.horizontal, maxWidth == nil ? 72 : 32)
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
