import SwiftUI

// Settings building blocks on the Signature palette (shared with the menu panel and
// transcript viewer). Native controls go inside rows; only containers are custom.

enum SettingsPageLayout {
    static let columnWidth: CGFloat = 680
    static let sideInset: CGFloat = 32

    /// Leading inset that centres the column in the *detail pane* (measured outside
    /// the scroll view). Centring inside the scroll content instead lets a legacy
    /// scroller, which appears only on long pages, shift those pages' column.
    static func leadingInset(forPaneWidth width: CGFloat) -> CGFloat {
        max(sideInset, (width - columnWidth) / 2)
    }
}

struct SettingsPageScaffold<Notice: View, Content: View>: View {
    /// `.column` centres the page in the standard reading column. `.fill` spans the
    /// whole pane and is at least as tall as it, so one flexible child (a table or
    /// library) can take the leftover height with `.frame(maxHeight: .infinity)`.
    enum Layout { case column, fill }

    let page: SettingsPage
    var layout: Layout = .column
    @ViewBuilder var notice: Notice
    @ViewBuilder var content: Content

    init(page: SettingsPage, layout: Layout = .column,
         @ViewBuilder notice: () -> Notice, @ViewBuilder content: () -> Content) {
        self.page = page
        self.layout = layout
        self.notice = notice()
        self.content = content()
    }

    private static var topPadding: CGFloat { 30 }
    private static var bottomPadding: CGFloat { 48 }

    var body: some View {
        GeometryReader { pane in
            let fills = layout == .fill
            let bottom = fills ? SettingsPageLayout.sideInset : Self.bottomPadding
            let leading = fills ? SettingsPageLayout.sideInset : SettingsPageLayout.leadingInset(forPaneWidth: pane.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsPageHeader(page: page)
                    notice
                    content
                }
                .frame(maxWidth: fills ? .infinity : SettingsPageLayout.columnWidth, alignment: .leading)
                .frame(minHeight: fills ? max(0, pane.size.height - Self.topPadding - bottom) : nil,
                       alignment: .top)
                .padding(.top, Self.topPadding)
                .padding(.leading, leading)
                .padding(.trailing, SettingsPageLayout.sideInset)
                .padding(.bottom, bottom)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlayScrollers()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// The page title block: icon tile, title, and subtitle. Pages that can't use the
/// scaffold (two-pane editors) place it themselves.
struct SettingsPageHeader: View {
    let page: SettingsPage
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accentText.color)
                .frame(width: 34, height: 34)
                .background(palette.selected.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title)
                    .uiFont(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .accessibilityAddTraits(.isHeader)
                if !page.subtitle.isEmpty {
                    Text(page.subtitle)
                        .uiFont(.system(size: 12))
                        .foregroundStyle(palette.secondary.color)
                }
            }
        }
    }
}

extension SettingsPageScaffold where Notice == EmptyView {
    init(page: SettingsPage, layout: Layout = .column, @ViewBuilder content: () -> Content) {
        self.init(page: page, layout: layout, notice: { EmptyView() }, content: content)
    }
}

struct SettingsCard<Content: View>: View {
    var title: LocalizedStringKey?
    var description: LocalizedStringKey?
    var section: SettingsSectionID?
    @ViewBuilder var content: Content
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerMode) private var mode

    init(_ title: LocalizedStringKey? = nil, description: LocalizedStringKey? = nil,
         section: SettingsSectionID? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.section = section
        self.content = content()
    }

    private var radius: CGFloat { mode.isPaper ? 8 : 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || description != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let title {
                        if let section {
                            SettingsSearchHeading(title, section: section, style: .system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.heading.color)
                        } else {
                            Text(title)
                                .uiFont(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.heading.color)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    if let description {
                        Text(description)
                            .uiFont(.system(size: 11.5))
                            .foregroundStyle(palette.secondary.color)
                    }
                }
                .padding(.horizontal, 2)
            } else if let section {
                Color.clear.frame(height: 0).id(section)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(palette.surface.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                // Every row draws a bottom hairline; hide the last one under the card's edge.
                .overlay(alignment: .bottom) {
                    palette.surface.color.frame(height: 1).padding(.horizontal, radius)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(palette.divider.color, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct SettingsRow<Control: View>: View {
    private let label: Text
    private let caption: Text?
    private let systemImage: String?
    @ViewBuilder private var control: Control
    @Environment(\.viewerPalette) private var palette

    init(_ label: LocalizedStringKey, caption: LocalizedStringKey? = nil, systemImage: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.label = Text(label)
        self.caption = caption.map { Text($0) }
        self.systemImage = systemImage
        self.control = control()
    }

    init(verbatim label: String, caption: String? = nil, systemImage: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.label = Text(verbatim: label)
        self.caption = caption.map { Text(verbatim: $0) }
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.heading.color)
                    .frame(width: 28, height: 28)
                    .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(palette.divider.color, lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                label
                    .uiFont(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.heading.color)
                if let caption {
                    caption
                        .uiFont(.system(size: 11.5))
                        .foregroundStyle(palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .labelsHidden()
                .fixedSize()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { SettingsHairline() }
        // Label + caption read as one element; every control stays its own element.
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Control == EmptyView {
    init(_ label: LocalizedStringKey, caption: LocalizedStringKey? = nil, systemImage: String? = nil) {
        self.init(label, caption: caption, systemImage: systemImage) { EmptyView() }
    }

    init(verbatim label: String, caption: String? = nil, systemImage: String? = nil) {
        self.init(verbatim: label, caption: caption, systemImage: systemImage) { EmptyView() }
    }
}

/// A row whose content spans the card (lists, grids, editors).
struct SettingsStackedRow<Content: View>: View {
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .overlay(alignment: .bottom) { SettingsHairline() }
    }
}

/// Row separator, inset 14 pt from the leading edge like the viewer's lists.
struct SettingsHairline: View {
    @Environment(\.viewerPalette) private var palette
    var body: some View {
        palette.divider.color.frame(height: 1).padding(.leading, 14).accessibilityHidden(true)
    }
}

struct SettingsStatusPill: View {
    enum Kind: Equatable { case success, warning, danger, neutral, accent }
    private let text: Text
    let kind: Kind
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    init(_ text: LocalizedStringKey, kind: Kind) { self.text = Text(text); self.kind = kind }
    init(verbatim text: String, kind: Kind) { self.text = Text(verbatim: text); self.kind = kind }

    private var foreground: Color {
        switch kind {
        case .success: status.success.color
        case .warning: status.warning.color
        case .danger: status.danger.color
        case .neutral: palette.secondary.color
        case .accent: palette.accentText.color
        }
    }

    private var fill: Color {
        switch kind {
        case .success: status.successFill.color
        case .warning: status.warning.color.opacity(0.14)
        case .danger: status.dangerFill.color
        case .neutral: palette.secondary.color.opacity(0.14)
        case .accent: palette.selected.color
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if kind != .accent {
                Circle().fill(foreground).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            text.uiFont(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(minHeight: 20)
        .background(fill, in: Capsule())
    }
}

struct SettingsNotice<Actions: View>: View {
    enum Tone { case info, warning }
    let text: Text
    var tone: Tone = .info
    @ViewBuilder var actions: Actions
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    init(_ text: Text, tone: Tone = .info, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.tone = tone
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tone == .info ? "person.2" : "exclamationmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tone == .info ? palette.accentText.color : status.warning.color)
                .accessibilityHidden(true)
            text
                .uiFont(.system(size: 12))
                .foregroundStyle(palette.heading.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(tone == .info ? palette.selected.color : status.warning.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SettingsAdvancedCard<Content: View>: View {
    let summary: LocalizedStringKey
    let sections: Set<SettingsSectionID>
    @ViewBuilder var content: Content
    @SceneStorage private var expanded: Bool
    @Environment(\.settingsSearchRequest) private var request
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerMode) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(page: SettingsPage, summary: LocalizedStringKey, sections: Set<SettingsSectionID>,
         @ViewBuilder content: () -> Content) {
        self.summary = summary
        self.sections = sections
        self.content = content()
        _expanded = SceneStorage(wrappedValue: false, "settings.advanced.\(page.rawValue)")
    }

    static func shouldExpand(request: SettingsSearchRequest?, sections: Set<SettingsSectionID>) -> Bool {
        guard let section = request?.section else { return false }
        return sections.contains(section)
    }

    /// Open on the very first render for a search target, so the page can scroll to
    /// the section before `onAppear` has persisted the expansion.
    static func isOpen(stored: Bool, request: SettingsSearchRequest?, sections: Set<SettingsSectionID>) -> Bool {
        stored || shouldExpand(request: request, sections: sections)
    }

    private var isOpen: Bool { Self.isOpen(stored: expanded, request: request, sections: sections) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { expanded = !isOpen }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(palette.secondary.color)
                    Text("Advanced")
                        .uiFont(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.heading.color)
                    Spacer()
                    Text(summary)
                        .uiFont(.system(size: 11.5))
                        .foregroundStyle(palette.secondary.color)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? Text("Expanded") : Text("Collapsed"))
            if isOpen {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding([.horizontal, .bottom], 8)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: mode.isPaper ? 8 : 12, style: .continuous)
                .strokeBorder(palette.divider.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
        }
        .onAppear { if Self.shouldExpand(request: request, sections: sections) { expanded = true } }
        .onChange(of: request) { _, new in if Self.shouldExpand(request: new, sections: sections) { expanded = true } }
    }
}

extension ButtonStyle where Self == MenuPanelButtonStyle {
    static var settingsSecondary: MenuPanelButtonStyle { MenuPanelButtonStyle(kind: .secondary, height: 26, fontSize: 12, fillsWidth: false) }
    static var settingsPrimary: MenuPanelButtonStyle { MenuPanelButtonStyle(kind: .hero, height: 26, fontSize: 12, fillsWidth: false) }
    static var settingsDanger: MenuPanelButtonStyle { MenuPanelButtonStyle(kind: .danger, height: 26, fontSize: 12, fillsWidth: false) }
}

/// A clickable list row on the palette: the sidebar's flat `selected` fill, a soft
/// hover fill, and the click action. Use instead of `List(selection:)`, whose
/// `NSTableView` always paints the system accent, never the app's.
private struct SettingsSelectableRowModifier: ViewModifier {
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.viewerPalette) private var palette

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .background(
                isSelected ? palette.selected.color : hovered ? palette.divider.color.opacity(0.35) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .onHover { hovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }
}

extension View {
    func settingsSelectableRow(isSelected: Bool, action: @escaping () -> Void) -> some View {
        modifier(SettingsSelectableRowModifier(isSelected: isSelected, action: action))
    }
}

/// The id an arrow key lands on in an ordered list: one step from `current`, clamped;
/// the first id when nothing is selected.
enum SettingsListNavigation {
    static func step<ID: Equatable>(_ step: Int, in ids: [ID], from current: ID?) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids[0] }
        return ids[min(max(index + step, 0), ids.count - 1)]
    }
}
