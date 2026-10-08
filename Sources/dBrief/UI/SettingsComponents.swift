import SwiftUI

// Settings building blocks on the Signature palette (shared with the menu panel and
// transcript viewer). Native controls go inside rows; only containers are custom.

struct SettingsPageScaffold<Notice: View, Content: View>: View {
    let page: SettingsPage
    @ViewBuilder var notice: Notice
    @ViewBuilder var content: Content
    @Environment(\.viewerPalette) private var palette

    init(page: SettingsPage, @ViewBuilder notice: () -> Notice, @ViewBuilder content: () -> Content) {
        self.page = page
        self.notice = notice()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
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
                notice
                content
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.top, 30)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

extension SettingsPageScaffold where Notice == EmptyView {
    init(page: SettingsPage, @ViewBuilder content: () -> Content) {
        self.init(page: page, notice: { EmptyView() }, content: content)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .labelsHidden()
                .fixedSize()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { SettingsHairline() }
        .accessibilityElement(children: .combine)
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
        .frame(height: 20)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
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
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding([.horizontal, .bottom], 8)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
