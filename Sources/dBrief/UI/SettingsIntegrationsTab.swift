import SwiftUI

struct SettingsIntegrationsTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var connectionMessages: [IntegrationDestination: String] = [:]
    @State private var isTesting: Set<IntegrationDestination> = []
    @State private var selectedDestination: IntegrationDestination? = nil
    private let integrationService = IntegrationDispatchService()

    var body: some View {
        Form {
            Section {
                ForEach(IntegrationDestination.available, id: \.self) { destination in
                    integrationRow(for: destination)
                }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .sheet(item: $selectedDestination) { destination in
            NavigationStack {
                integrationDetail(destination)
                    .navigationTitle(destination.displayName)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selectedDestination = nil }
                        }
                    }
            }
            .frame(minWidth: 420, minHeight: 360)
        }
    }

    // Each row shows an inline toggle (quick enable/disable) and a chevron button
    // that opens the configuration sheet — matches macOS Notifications preferences pattern.
    private func integrationRow(for destination: IntegrationDestination) -> some View {
        HStack(spacing: 12) {
            integrationIcon(for: destination)
                .frame(width: 32, height: 32)
            Text(destination.displayName)
            Spacer()
            Toggle("", isOn: enabledBinding(for: destination))
                .labelsHidden()
            Button {
                selectedDestination = destination
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private func integrationDetail(_ destination: IntegrationDestination) -> some View {
        Form {
            switch destination {
            case .obsidian:        obsidianDetail
            case .appleNotes:      appleNotesDetail
            case .appleReminders:  appleRemindersDetail
            case .notion:          notionDetail
            case .evernote:        evernoteDetail
            case .googleKeep:      googleKeepDetail
            case .oneNote:         oneNoteDetail
            case .webhook:         webhookDetail
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Detail views

    @ViewBuilder private var obsidianDetail: some View {
        Section {
            Toggle("Enable Obsidian", isOn: binding({ appSettings.obsidianEnabled }, { appSettings.obsidianEnabled = $0 }))
        }
        if appSettings.obsidianEnabled {
            Section("Configuration") {
                LabeledContent("Vault") {
                    HStack {
                        Text(vaultPathText)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseVault { url in appSettings.obsidianVaultURL = url } }
                            .buttonStyle(.bordered)
                    }
                }
                LabeledContent("Default folder") {
                    HStack {
                        Text(appSettings.obsidianFolderDisplayName(relativePath: appSettings.obsidianDefaultFolderRelativePath))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") {
                            chooseFolderInVault { relativePath in appSettings.obsidianDefaultFolderRelativePath = relativePath }
                        }
                        .buttonStyle(.bordered)
                        .disabled(appSettings.obsidianVaultURL == nil)
                    }
                }
                if appSettings.obsidianVaultURL == nil {
                    Text("Select an Obsidian vault to enable folder selection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Include transcript in notes", isOn: binding({ appSettings.obsidianIncludeTranscript }, { appSettings.obsidianIncludeTranscript = $0 }))
            }
        }
    }

    @ViewBuilder private var appleNotesDetail: some View {
        Section {
            Toggle("Enable Apple Notes", isOn: binding(
                { appSettings.integrations.appleNotes.enabled },
                { appSettings.integrations.appleNotes.enabled = $0 }
            ))
        }
        if appSettings.integrations.appleNotes.enabled {
            Section("Configuration") {
                TextField("Account name", text: binding(
                    { appSettings.integrations.appleNotes.accountName },
                    { appSettings.integrations.appleNotes.accountName = $0 }
                ))
                TextField("Folder name", text: binding(
                    { appSettings.integrations.appleNotes.folderName },
                    { appSettings.integrations.appleNotes.folderName = $0 }
                ))
            }
            deliverySection(
                get: { appSettings.integrations.appleNotes.fields },
                set: { appSettings.integrations.appleNotes.fields = $0 }
            )
            Section { testButton(for: .appleNotes) }
        }
    }

    @ViewBuilder private var appleRemindersDetail: some View {
        Section {
            Toggle("Enable Apple Reminders", isOn: binding(
                { appSettings.integrations.appleReminders.enabled },
                { appSettings.integrations.appleReminders.enabled = $0 }
            ))
        }
        if appSettings.integrations.appleReminders.enabled {
            Section("Configuration") {
                TextField("Default list name", text: binding(
                    { appSettings.integrations.appleReminders.listName },
                    { appSettings.integrations.appleReminders.listName = $0 }
                ))
                Text("Only action items are sent as reminders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section { testButton(for: .appleReminders) }
        }
    }

    @ViewBuilder private var notionDetail: some View {
        Section {
            Toggle("Enable Notion", isOn: binding(
                { appSettings.integrations.notion.enabled },
                { appSettings.integrations.notion.enabled = $0 }
            ))
        }
        if appSettings.integrations.notion.enabled {
            Section("Configuration") {
                SecureField("Notion token", text: binding({ appSettings.notionToken }, { appSettings.notionToken = $0 }))
                Picker("Parent type", selection: binding(
                    { appSettings.integrations.notion.parentType },
                    { appSettings.integrations.notion.parentType = $0 }
                )) {
                    Text("Data source").tag(NotionParentType.dataSource)
                    Text("Page").tag(NotionParentType.page)
                }
                TextField("Parent ID", text: binding(
                    { appSettings.integrations.notion.parentID },
                    { appSettings.integrations.notion.parentID = $0 }
                ))
                TextField("Title property", text: binding(
                    { appSettings.integrations.notion.titlePropertyName },
                    { appSettings.integrations.notion.titlePropertyName = $0 }
                ))
                if appSettings.notionToken.isEmpty || appSettings.integrations.notion.parentID.isEmpty {
                    Text("Token and parent ID are required.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            deliverySection(
                get: { appSettings.integrations.notion.fields },
                set: { appSettings.integrations.notion.fields = $0 }
            )
            Section { testButton(for: .notion) }
        }
    }

    @ViewBuilder private var evernoteDetail: some View {
        Section {
            Toggle("Enable Evernote", isOn: binding(
                { appSettings.integrations.evernote.enabled },
                { appSettings.integrations.evernote.enabled = $0 }
            ))
        }
        if appSettings.integrations.evernote.enabled {
            Section("Configuration") {
                SecureField("Evernote token", text: binding({ appSettings.evernoteToken }, { appSettings.evernoteToken = $0 }))
                TextField("API base URL", text: binding(
                    { appSettings.integrations.evernote.apiBaseURL },
                    { appSettings.integrations.evernote.apiBaseURL = $0 }
                ))
                TextField("Notebook ID", text: binding(
                    { appSettings.integrations.evernote.notebookID },
                    { appSettings.integrations.evernote.notebookID = $0 }
                ))
                if appSettings.evernoteToken.isEmpty {
                    Text("Token is required.").font(.caption).foregroundStyle(.orange)
                }
            }
            deliverySection(
                get: { appSettings.integrations.evernote.fields },
                set: { appSettings.integrations.evernote.fields = $0 }
            )
            Section { testButton(for: .evernote) }
        }
    }

    @ViewBuilder private var googleKeepDetail: some View {
        Section {
            Toggle("Enable Google Keep", isOn: binding(
                { appSettings.integrations.googleKeep.enabled },
                { appSettings.integrations.googleKeep.enabled = $0 }
            ))
        }
        if appSettings.integrations.googleKeep.enabled {
            Section("Configuration") {
                SecureField("Google OAuth token", text: binding({ appSettings.googleKeepToken }, { appSettings.googleKeepToken = $0 }))
                TextField("API base URL", text: binding(
                    { appSettings.integrations.googleKeep.apiBaseURL },
                    { appSettings.integrations.googleKeep.apiBaseURL = $0 }
                ))
                Text("Google Keep API is enterprise-oriented and may require Workspace setup.")
                    .font(.caption).foregroundStyle(.secondary)
                if appSettings.googleKeepToken.isEmpty {
                    Text("Token is required.").font(.caption).foregroundStyle(.orange)
                }
            }
            deliverySection(
                get: { appSettings.integrations.googleKeep.fields },
                set: { appSettings.integrations.googleKeep.fields = $0 }
            )
            Section { testButton(for: .googleKeep) }
        }
    }

    @ViewBuilder private var oneNoteDetail: some View {
        Section {
            Toggle("Enable Microsoft OneNote", isOn: binding(
                { appSettings.integrations.oneNote.enabled },
                { appSettings.integrations.oneNote.enabled = $0 }
            ))
        }
        if appSettings.integrations.oneNote.enabled {
            Section("Configuration") {
                SecureField("Microsoft Graph token", text: binding({ appSettings.oneNoteToken }, { appSettings.oneNoteToken = $0 }))
                TextField("Graph base URL", text: binding(
                    { appSettings.integrations.oneNote.graphBaseURL },
                    { appSettings.integrations.oneNote.graphBaseURL = $0 }
                ))
                TextField("Section ID", text: binding(
                    { appSettings.integrations.oneNote.sectionID },
                    { appSettings.integrations.oneNote.sectionID = $0 }
                ))
                if appSettings.oneNoteToken.isEmpty {
                    Text("Token is required.").font(.caption).foregroundStyle(.orange)
                }
            }
            deliverySection(
                get: { appSettings.integrations.oneNote.fields },
                set: { appSettings.integrations.oneNote.fields = $0 }
            )
            Section { testButton(for: .oneNote) }
        }
    }

    @ViewBuilder private var webhookDetail: some View {
        Section {
            Toggle("Enable Webhook", isOn: binding(
                { appSettings.integrations.webhook.enabled },
                { appSettings.integrations.webhook.enabled = $0 }
            ))
        }
        if appSettings.integrations.webhook.enabled {
            Section("Configuration") {
                TextField("Webhook URL", text: binding(
                    { appSettings.integrations.webhook.url },
                    { appSettings.integrations.webhook.url = $0 }
                ))
                LabeledContent("Timeout") {
                    HStack {
                        TextField("", value: binding(
                            { appSettings.integrations.webhook.timeoutSeconds },
                            { appSettings.integrations.webhook.timeoutSeconds = $0 }
                        ), format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Retries") {
                    Stepper(value: binding(
                        { appSettings.integrations.webhook.retryCount },
                        { appSettings.integrations.webhook.retryCount = $0 }
                    ), in: 0...5) {
                        Text("\(appSettings.integrations.webhook.retryCount)")
                    }
                }
                if appSettings.integrations.webhook.url.isEmpty {
                    Text("Webhook URL is required.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Headers") {
                ForEach(Array(appSettings.integrations.webhook.headers.enumerated()), id: \.element.id) { index, header in
                    HStack {
                        TextField("Name", text: binding(
                            { headerValue(index: index).key },
                            { updateHeader(index: index, key: $0, value: headerValue(index: index).value) }
                        ))
                        TextField("Value", text: binding(
                            { headerValue(index: index).value },
                            { updateHeader(index: index, key: headerValue(index: index).key, value: $0) }
                        ))
                        Button { removeHeader(id: header.id) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    appSettings.integrations.webhook.headers.append(WebhookHeader())
                } label: {
                    Label("Add Header", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            deliverySection(
                get: { appSettings.integrations.webhook.fields },
                set: { appSettings.integrations.webhook.fields = $0 }
            )
            Section { testButton(for: .webhook) }
        }
    }

    // MARK: - Shared helpers

    private func deliverySection(
        get: @escaping () -> [DeliveryField],
        set: @escaping ([DeliveryField]) -> Void
    ) -> some View {
        Section("Send fields") {
            ForEach(DeliveryField.allCases) { field in
                Toggle(field.displayName, isOn: binding(
                    { get().contains(field) },
                    { isOn in
                        var current = get()
                        if isOn { if !current.contains(field) { current.append(field) } }
                        else { current.removeAll { $0 == field } }
                        set(current)
                    }
                ))
            }
        }
    }

    private func enabledBinding(for destination: IntegrationDestination) -> Binding<Bool> {
        switch destination {
        case .obsidian:
            binding({ appSettings.obsidianEnabled }, { appSettings.obsidianEnabled = $0 })
        case .appleNotes:
            binding({ appSettings.integrations.appleNotes.enabled }, { appSettings.integrations.appleNotes.enabled = $0 })
        case .appleReminders:
            binding({ appSettings.integrations.appleReminders.enabled }, { appSettings.integrations.appleReminders.enabled = $0 })
        case .notion:
            binding({ appSettings.integrations.notion.enabled }, { appSettings.integrations.notion.enabled = $0 })
        case .evernote:
            binding({ appSettings.integrations.evernote.enabled }, { appSettings.integrations.evernote.enabled = $0 })
        case .googleKeep:
            binding({ appSettings.integrations.googleKeep.enabled }, { appSettings.integrations.googleKeep.enabled = $0 })
        case .oneNote:
            binding({ appSettings.integrations.oneNote.enabled }, { appSettings.integrations.oneNote.enabled = $0 })
        case .webhook:
            binding({ appSettings.integrations.webhook.enabled }, { appSettings.integrations.webhook.enabled = $0 })
        }
    }

    private func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { @MainActor in get() }, set: { @MainActor value in set(value) })
    }

    @ViewBuilder
    private func integrationIcon(for destination: IntegrationDestination) -> some View {
        iconTile {
            if let image = integrationIconImage(for: destination) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: icon(for: destination))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18, weight: .medium))
            }
        }
    }

    private func integrationIconImage(for destination: IntegrationDestination) -> NSImage? {
        let baseNames = iconFileBaseNames(for: destination)
        let searchNames = Set(baseNames + baseNames.map { $0.lowercased() })
        let extensions = ["png", "jpg", "jpeg", "pdf", "icns", "webp", ""]

        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        for name in searchNames {
            for ext in extensions {
                let fileName = ext.isEmpty ? name : "\(name).\(ext)"
                let url = resourceURL.appendingPathComponent("3dPartyIcons/\(fileName)")
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }
        return nil
    }

    private func iconFileBaseNames(for destination: IntegrationDestination) -> [String] {
        switch destination {
        case .obsidian:        ["Obsidian", destination.rawValue, destination.displayName]
        case .appleNotes:      ["Apple Notes", destination.rawValue, destination.displayName]
        case .appleReminders:  ["Apple Reminders", destination.rawValue, destination.displayName]
        case .notion:          ["Notion", destination.rawValue, destination.displayName]
        case .evernote:        ["Evernote", destination.rawValue, destination.displayName]
        case .googleKeep:      ["Google Keep", destination.rawValue, destination.displayName]
        case .oneNote:         ["OneNote", "Microsoft OneNote", destination.rawValue, destination.displayName]
        case .webhook:         ["Webhook", destination.rawValue, destination.displayName]
        }
    }

    private func iconTile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill))
            content()
        }
    }

    private func icon(for destination: IntegrationDestination) -> String {
        switch destination {
        case .obsidian:       "diamond.fill"
        case .appleNotes:     "note.text"
        case .appleReminders: "checklist"
        case .notion:         "doc.text.fill"
        case .evernote:       "leaf.fill"
        case .googleKeep:     "lightbulb"
        case .oneNote:        "book.closed"
        case .webhook:        "network"
        }
    }

    private func testButton(for destination: IntegrationDestination) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await runConnectionTest(destination: destination) }
            } label: {
                Text(isTesting.contains(destination) ? "Testing…" : "Test connection")
            }
            .buttonStyle(.bordered)
            .disabled(isTesting.contains(destination))

            if let message = connectionMessages[destination] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == "Connection successful" ? Color.green : Color.red)
            }
        }
    }

    @MainActor
    private func runConnectionTest(destination: IntegrationDestination) async {
        isTesting.insert(destination)
        defer { isTesting.remove(destination) }
        do {
            try await integrationService.testConnection(destination: destination, settings: appSettings)
            connectionMessages[destination] = "Connection successful"
        } catch {
            connectionMessages[destination] = error.localizedDescription
        }
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
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
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

    private func headerValue(index: Int) -> WebhookHeader {
        guard appSettings.integrations.webhook.headers.indices.contains(index) else { return WebhookHeader() }
        return appSettings.integrations.webhook.headers[index]
    }

    private func updateHeader(index: Int, key: String, value: String) {
        guard appSettings.integrations.webhook.headers.indices.contains(index) else { return }
        appSettings.integrations.webhook.headers[index].key = key
        appSettings.integrations.webhook.headers[index].value = value
    }

    private func removeHeader(id: UUID) {
        appSettings.integrations.webhook.headers.removeAll { $0.id == id }
    }
}
