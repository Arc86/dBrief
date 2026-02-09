import SwiftUI

struct SettingsIntegrationsTab: View {
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var settings = appSettings

        Form {
            Section("Integrations") {
                Toggle("Enable Obsidian", isOn: $settings.obsidianEnabled)

                if appSettings.obsidianEnabled {
                    LabeledContent("Vault:") {
                        HStack {
                            Text(vaultPathText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Choose...") {
                                chooseVault { url in
                                    appSettings.obsidianVaultURL = url
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    LabeledContent("Default output:") {
                        HStack {
                            Text(appSettings.obsidianFolderDisplayName(relativePath: appSettings.obsidianDefaultFolderRelativePath))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Choose...") {
                                chooseFolderInVault { relativePath in
                                    appSettings.obsidianDefaultFolderRelativePath = relativePath
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(appSettings.obsidianVaultURL == nil)
                        }
                    }

                    if appSettings.obsidianVaultURL == nil {
                        Text("Select an Obsidian vault to enable folder selection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var vaultPathText: String {
        if let url = appSettings.obsidianVaultURL {
            return url.path(percentEncoded: false)
        }
        return "Not set"
    }

    private func chooseVault(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose your Obsidian vault folder"
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func chooseFolderInVault(completion: @escaping (String) -> Void) {
        guard let vaultURL = appSettings.obsidianVaultURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = vaultURL
        panel.message = "Choose a folder inside your Obsidian vault"
        if panel.runModal() == .OK, let url = panel.url {
            guard let relativePath = appSettings.obsidianRelativePath(for: url) else { return }
            completion(relativePath)
        }
    }
}
