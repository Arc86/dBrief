import SwiftUI

// Building blocks for the "Signature" menu bar panel. Colours come only from the
// viewer palette (shared with the transcript viewer) and the panel's status
// palette, so Light, Dark, Paper, Dark Paper, the accent and Reduce neon all
// follow the user's appearance settings.

struct MenuPanelButtonStyle: ButtonStyle {
    enum Kind { case hero, secondary, row, danger, dangerFilled, accentOutline, tile, dangerTile, quiet }
    var kind: Kind
    var height: CGFloat = 30
    var fontSize: CGFloat? = nil
    /// Secondary actions stretch to share a row; set false for a button sized to its label.
    var fillsWidth = true
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: kind == .hero ? 9 : 7, style: .continuous)
        configuration.label
            .uiFont(.system(size: fontSize ?? defaultFontSize, weight: kind == .hero ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .quiet ? 0 : 10)
            .frame(maxWidth: kind == .quiet || !fillsWidth ? nil : .infinity, minHeight: height)
            .background(background, in: shape)
            .overlay {
                if let border {
                    shape.strokeBorder(border, lineWidth: kind == .accentOutline ? 1.5 : 1).allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(shape)
    }

    private var defaultFontSize: CGFloat {
        switch kind {
        case .hero: 14
        case .tile, .dangerTile, .quiet: 11
        default: 12
        }
    }

    private var foreground: Color {
        switch kind {
        case .hero: palette.onPrimary.color
        case .danger, .dangerTile: status.danger.color
        case .dangerFilled: status.onDanger.color
        case .accentOutline: palette.heading.color
        case .quiet: palette.secondary.color
        default: palette.text.color
        }
    }

    private var background: Color {
        switch kind {
        case .hero: palette.primary.color
        case .row: palette.canvas.color
        case .danger: status.dangerFill.color
        case .dangerFilled: status.danger.color
        case .quiet: .clear
        default: palette.surface.color
        }
    }

    private var border: Color? {
        switch kind {
        case .hero, .quiet, .dangerFilled: nil
        case .danger: status.dangerBorder.color
        case .accentOutline: palette.primary.color
        default: palette.divider.color
        }
    }
}

/// The Recording library entry: a soft accent tint with no outline, so it reads
/// as the way into the app while staying calm. Glyphs in the label take the
/// accent; the text stays heading-coloured.
struct MenuPanelLibraryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .uiFont(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.heading.color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(status.libraryFill.color, in: shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(shape)
    }
}

/// A flat strip of the panel, split from the next by a full-bleed hairline.
struct MenuPanelSection<Content: View>: View {
    var showsDivider = true
    var spacing: CGFloat = 8
    var verticalPadding: CGFloat = 11
    @ViewBuilder var content: Content
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if showsDivider { MenuPanelHairline() }
            }
    }
}

struct MenuPanelHairline: View {
    @Environment(\.viewerPalette) private var palette
    var body: some View {
        Rectangle().fill(palette.divider.color).frame(height: 1).accessibilityHidden(true)
    }
}

/// Label chrome for the panel's dropdowns (profile, microphone, meeting).
struct MenuPanelSelectorLabel: View {
    let text: String
    var tint: Color? = nil
    var height: CGFloat = 26
    var filled = true
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .uiFont(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint ?? palette.heading.color)
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(filled ? palette.canvas.color : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if filled {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(palette.divider.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The dBrief mark: five rounded bars in the brand stops (flat accent when Reduce neon is on).
struct BrandBarsMark: View {
    @Environment(\.viewerPalette) private var palette
    var height: CGFloat = 24
    private let ratios: [CGFloat] = [9, 18, 24, 15, 7].map { $0 / 24 }

    var body: some View {
        HStack(alignment: .center, spacing: max(1, height / 12)) {
            ForEach(Array(ratios.enumerated()), id: \.offset) { index, ratio in
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.brandStops[min(index + 1, palette.brandStops.count - 1)].color)
                    .frame(width: max(2, height / 8), height: height * ratio)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Scrolls only once its content outgrows `maxHeight`. Inside the panel's own scroll
/// view a plain ScrollView gets no height proposal, so the content is measured.
struct MenuPanelBoundedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content.background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MenuPanelBoundedHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(MenuPanelBoundedHeightKey.self) { contentHeight = $0 }
    }
}

private struct MenuPanelBoundedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension MenuPanelStatus.Tone {
    func color(palette: ViewerPalette, status: MenuPanelPalette) -> Color {
        switch self {
        case .success: status.success.color
        case .danger: status.danger.color
        case .warning: status.warning.color
        case .accent: palette.primary.color
        }
    }
}

struct MenuPanelStatusDot: View {
    let tone: MenuPanelStatus.Tone
    var pulse = false
    var size: CGFloat = 7
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(tone.color(palette: palette, status: status))
            .frame(width: size, height: size)
            .opacity(Self.opacity(pulse: pulse && !reduceMotion, dimmed: dimmed))
            .onAppear { startPulse() }
            .onChange(of: pulse) { _, _ in startPulse() }
            .accessibilityHidden(true)
    }

    /// Dimming only shows while pulsing, so a stopped or re-appearing dot is never stuck pale.
    static func opacity(pulse: Bool, dimmed: Bool) -> Double {
        pulse && dimmed ? 0.35 : 1
    }

    private func startPulse() {
        dimmed = false
        guard pulse, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// Live input level as a scrolling row of thin accent bars: each meter tick adds a
/// smoothed sample on the right (fast rise, slower fall), so speech reads as a
/// waveform instead of every bar jumping at once.
struct MenuPanelLevelBars: View {
    let level: Float
    var active = true
    var height: CGFloat = 30
    @Environment(\.menuPanelPalette) private var status
    @State private var history = [CGFloat](repeating: 0, count: Self.historyLength)

    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 3
    private static let historyLength = 80

    var body: some View {
        let colour = status.accentMark.color
        let samples = history
        Canvas { context, size in
            let count = min(samples.count, max(1, Int((size.width + Self.gap) / (Self.barWidth + Self.gap))))
            let visible = samples.suffix(count)
            let used = CGFloat(count) * Self.barWidth + CGFloat(count - 1) * Self.gap
            var x = size.width - used
            for value in visible {
                let h = max(3, (0.1 + 0.9 * value) * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: Self.barWidth, height: h)
                // Quiet samples fade back so silence reads as a soft baseline, not a row of dots.
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(colour.opacity(0.35 + 0.65 * min(1, value * 2))))
                x += Self.barWidth + Self.gap
            }
        }
        .frame(height: height)
        .opacity(active ? 1 : 0.4)
        .onChange(of: level) { _, newLevel in
            guard active else { return }
            history.append(Self.smoothed(previous: history.last ?? 0, target: CGFloat(AudioLevelMeter.displayLevel(newLevel))))
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int((history.last ?? 0) * 100)) percent")
    }

    /// Rise quickly to a louder sample, fall back gently: no flicker between ticks.
    static func smoothed(previous: CGFloat, target: CGFloat) -> CGFloat {
        let rate: CGFloat = target > previous ? 0.6 : 0.3
        return previous + (target - previous) * rate
    }
}

/// The menu bar panel floats above every window, so anything it opens — a window,
/// an open panel — must close it first or it ends up behind it.
/// Gives the MenuBarExtra window the app's theme appearance. Unlike regular windows,
/// the menu bar window ignores SwiftUI's `preferredColorScheme`, so with a dark app
/// theme on a light system it kept the Aqua frame and its light outline around the
/// dark panel.
struct MenuPanelWindowAppearance: NSViewRepresentable {
    let mode: ViewerAppearanceMode

    static func appearanceName(for mode: ViewerAppearanceMode) -> NSAppearance.Name {
        mode.isDark ? .darkAqua : .aqua
    }

    func makeNSView(context: Context) -> WindowView { WindowView(name: Self.appearanceName(for: mode)) }

    func updateNSView(_ view: WindowView, context: Context) {
        view.name = Self.appearanceName(for: mode)
        view.apply()
    }

    final class WindowView: NSView {
        var name: NSAppearance.Name

        init(name: NSAppearance.Name) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, window.appearance?.name != name else { return }
            window.appearance = NSAppearance(named: name)
        }
    }
}

@MainActor
enum MenuBarPanel {
    static func close() {
        // SwiftUI's MenuBarExtra window sits at the pop-up menu level (not .statusBar,
        // which is the status item itself — hiding that would remove the icon).
        for window in NSApp.windows where isMenuBarExtraWindow(window) {
            window.orderOut(nil)
        }
    }

    static func isMenuBarExtraWindow(_ window: NSWindow) -> Bool {
        let name = String(describing: type(of: window))
        if name.contains("MenuBarExtra") { return true }
        return window.level == .popUpMenu && !name.contains("StatusBar") && !(window is NSPanel)
    }

    /// The window that hosts the menu bar icon itself.
    static func isStatusItemWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("StatusBarWindow")
    }

    /// Opens the panel as if the icon were clicked; no-op when it is already open.
    static func show() {
        guard !NSApp.windows.contains(where: { isMenuBarExtraWindow($0) && $0.isVisible }) else { return }
        statusButton()?.performClick(nil)
    }

    static func statusButton() -> NSButton? {
        firstButton(in: NSApp.windows.first(where: isStatusItemWindow)?.contentView)
    }

    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { firstButton(in: $0) }.first
    }

    static func open(_ id: String, with openWindow: OpenWindowAction) {
        close()
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens a file or folder in its app (Finder, an editor), brought to the front.
    static func open(_ url: URL) {
        close()
        // macOS only lets another app come forward when the active app hands over
        // activation. The menu panel doesn't make dBrief active, so take activation
        // first (the click in the panel allows it), then yield it.
        NSApp.activate()
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
           let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    /// Reveals a file in Finder, brought to the front.
    static func reveal(_ url: URL) {
        close()
        let finder = "com.apple.finder"
        NSApp.activate()
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: finder)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        NSRunningApplication.runningApplications(withBundleIdentifier: finder).first?.activate()
    }

    /// Runs an open/save panel in front of other apps' windows.
    static func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        close()
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .modalPanel
        return panel.runModal()
    }
}

extension View {
    /// The 360 pt panel card: surface fill, hairline border, radius 18.
    func menuPanelCard(palette: ViewerPalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return self
            .background(palette.surface.color, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(palette.divider.color, lineWidth: 1).allowsHitTesting(false) }
    }
}
