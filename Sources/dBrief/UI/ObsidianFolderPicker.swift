import SwiftUI

struct ObsidianFolderPicker: View {
    @Environment(AppSettings.self) private var appSettings

    let title: String
    let currentRelativePath: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text(appSettings.obsidianFolderDisplayName(relativePath: currentRelativePath))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose...") {
                    chooseFolderInVault { relativePath in
                        onSelect(relativePath)
                    }
                }
                .disabled(appSettings.obsidianVaultURL == nil)
            }

            if appSettings.obsidianVaultURL == nil {
                Text("Select an Obsidian vault in Settings > Integrations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
