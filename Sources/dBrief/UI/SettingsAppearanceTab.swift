import SwiftUI

struct SettingsAppearanceTab: View {
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var settings = appSettings
        SettingsPageScaffold(page: .appearance) {
            SettingsAppearanceEditor(
                preferences: $settings.viewerAppearance,
                typography: $settings.uiTypography,
                nonNeon: $settings.reduceNeon
            )
        }
    }
}
