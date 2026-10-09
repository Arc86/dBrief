import SwiftUI
import AppKit

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(UpdaterController.self) private var updaterController
    /// Read in `.task`: a stored default would query ServiceManagement on every init.
    @State private var startAtLogin = false

    var body: some View {
        @Bindable var settings = appSettings
        @Bindable var updater = updaterController
        SettingsPageScaffold(page: .general) {
            SettingsCard("Startup", section: .appBehavior) {
                SettingsRow("Start at login") {
                    Toggle("Start at login", isOn: startAtLoginBinding)
                }
                SettingsRow("Show dock icon", caption: "Settings always shows one while it's open.") {
                    Toggle("Show dock icon", isOn: $settings.showDockIcon)
                }
            }

            SettingsCard("Updates", section: .softwareUpdate) {
                SettingsRow("Check for updates automatically", caption: lastCheckedCaption) {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                        .disabled(!updaterController.isAvailable)
                }
                SettingsRow("Check now") {
                    Button("Check now") { updaterController.checkForUpdates() }
                        .buttonStyle(.settingsSecondary)
                        .disabled(!updaterController.canCheckForUpdates)
                }
            }

            SettingsCard("Setup", section: .setupGuide) {
                SettingsRow("Welcome and setup guide", caption: "Opens again the next time you open the menu bar.") {
                    Button("Show again") { appSettings.hasCompletedOnboarding = false }
                        .buttonStyle(.settingsSecondary)
                }
            }
        }
        .task { startAtLogin = LoginItemManager.isEnabled }
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { startAtLogin },
            set: { newValue in
                startAtLogin = LoginItemManager.setEnabled(newValue) ? newValue : LoginItemManager.isEnabled
            }
        )
    }

    private var lastCheckedCaption: LocalizedStringKey? {
        updaterController.lastUpdateCheckDate.map {
            "Last checked \($0.formatted(date: .abbreviated, time: .shortened))."
        }
    }
}
