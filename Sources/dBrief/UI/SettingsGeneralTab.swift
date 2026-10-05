import SwiftUI
import AppKit

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(UpdaterController.self) private var updaterController
    @State private var startAtLogin: Bool = LoginItemManager.isEnabled

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("App Behavior", settingsSearch: .appBehavior) {
                Toggle("Start at login", isOn: Binding(
                    get: { startAtLogin },
                    set: { newValue in
                        if LoginItemManager.setEnabled(newValue) {
                            startAtLogin = newValue
                        } else {
                            startAtLogin = LoginItemManager.isEnabled
                        }
                    }
                ))
                Toggle("Show dock icon", isOn: $settings.showDockIcon)
                Toggle("Show advanced settings", isOn: $settings.powerUserMode)
                Text("Shows benchmarks, model options, and custom prompts. Profiles are always available.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Software Update", settingsSearch: .softwareUpdate) {
                LabeledContent("Check for updates") {
                    Button("Check Now") {
                        updaterController.checkForUpdates()
                    }
                    .disabled(!updaterController.canCheckForUpdates)
                }

                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updaterController.automaticallyChecksForUpdates },
                    set: { updaterController.automaticallyChecksForUpdates = $0 }
                ))

                if let lastCheck = updaterController.lastUpdateCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            Section("Setup Guide", settingsSearch: .setupGuide) {
                LabeledContent("Welcome and setup guide") {
                    Button("Show Again") {
                        appSettings.hasCompletedOnboarding = false
                    }
                    .buttonStyle(.typographyBordered)
                }
                Text("Shows the welcome and setup guide again the next time you open the menu bar.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
        .settingsFormStyle()
    }
}
