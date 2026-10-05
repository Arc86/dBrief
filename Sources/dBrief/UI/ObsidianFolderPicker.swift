import SwiftUI

struct ObsidianFolderPicker: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette

    let title: String
    let currentRelativePath: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .uiFont(.system(size: 12))
                .foregroundStyle(palette.secondary.color)

            HStack(spacing: 8) {
                Text(appSettings.obsidianFolderDisplayName(relativePath: currentRelativePath))
                    .uiFont(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(palette.text.color)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose…") {
                    chooseFolderInVault { relativePath in
                        onSelect(relativePath)
                    }
                }
                .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 35, fillsWidth: false))
                .disabled(appSettings.obsidianVaultURL == nil)
            }

            if appSettings.obsidianVaultURL == nil {
                Text("Select an Obsidian vault in Settings > Integrations.")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
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
