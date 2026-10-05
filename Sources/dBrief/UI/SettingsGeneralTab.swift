import SwiftUI
import AppKit

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(UpdaterController.self) private var updaterController
    @State private var startAtLogin: Bool = LoginItemManager.isEnabled

    var body: some View {
        @Bindable var settings = appSettings
        Form {
                Section("Appearance", settingsSearch: .appearance) {
                    SettingsAppearanceEditor(
                        preferences: $settings.viewerAppearance,
                        typography: $settings.uiTypography,
                        nonNeon: $settings.reduceNeon
                    )
                }
                .listRowBackground(Color.clear)

                Section("App behavior") {
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

                Section("Software update", settingsSearch: .softwareUpdate) {
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

                Section("Setup guide", settingsSearch: .setupGuide) {
                    LabeledContent("Setup guide") {
                        Button("Show setup guide again") {
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
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
    }
}
