import SwiftUI

struct SettingsSearchRequest: Equatable, Sendable {
    let section: SettingsSectionID
    let id = UUID()
}

extension EnvironmentValues {
    @Entry var settingsSearchRequest: SettingsSearchRequest? = nil
}

/// Search focuses this one visible heading. Applying focus modifiers to a Section
/// instead lets SwiftUI distribute them to its last form child.
struct SettingsSearchHeading: View {
    private let text: Text
    let section: SettingsSectionID
    var style: AppFontStyle = .headline
    @Environment(\.settingsSearchRequest) private var request
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool

    init(_ title: LocalizedStringKey, section: SettingsSectionID, style: AppFontStyle = .headline) {
        self.init(Text(title), section: section, style: style)
    }

    init(_ text: Text, section: SettingsSectionID, style: AppFontStyle = .headline) {
        self.text = text
        self.section = section
        self.style = style
    }

    var body: some View {
        text
            .uiFont(style)
            .id(section)
            .focusable(request?.section == section)
            .focused($keyboardFocused)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($accessibilityFocused)
            .task(id: request) {
                guard request?.section == section else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                keyboardFocused = true
                accessibilityFocused = true
            }
    }
}
