import SwiftUI

struct SettingsSearchRequest: Equatable, Sendable {
    let section: SettingsSectionID
    let id = UUID()
}

private struct SettingsSearchRequestKey: EnvironmentKey {
    static let defaultValue: SettingsSearchRequest? = nil
}
private struct SettingsSearchAdvancedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsSearchRequest: SettingsSearchRequest? {
        get { self[SettingsSearchRequestKey.self] }
        set { self[SettingsSearchRequestKey.self] = newValue }
    }
    var settingsSearchRevealAdvanced: Bool {
        get { self[SettingsSearchAdvancedKey.self] }
        set { self[SettingsSearchAdvancedKey.self] = newValue }
    }
}

/// Search focuses this one visible heading. Applying focus modifiers to a Section
/// instead lets SwiftUI distribute them to its last form child.
struct SettingsSearchHeading: View {
    private let text: Text
    let section: SettingsSectionID
    @Environment(\.settingsSearchRequest) private var request
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool

    init(_ title: LocalizedStringKey, section: SettingsSectionID) {
        self.init(Text(title), section: section)
    }

    init(_ text: Text, section: SettingsSectionID) {
        self.text = text
        self.section = section
    }

    var body: some View {
        text
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

// Keep the native Section structure and grouped Form layout. Only the heading
// receives the search identity and focus, never the section's controls.
extension Section where Parent == SettingsSearchHeading, Content: View, Footer == EmptyView {
    @MainActor
    init(_ title: LocalizedStringKey, settingsSearch section: SettingsSectionID,
         @ViewBuilder content: () -> Content) {
        self.init(content: content) {
            SettingsSearchHeading(title, section: section)
        }
    }
}
