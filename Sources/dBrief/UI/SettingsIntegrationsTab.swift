import SwiftUI

struct SettingsIntegrationsTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var connectionMessages: [IntegrationDestination: String] = [:]
    @State private var isTesting: Set<IntegrationDestination> = []
    private let integrationService = IntegrationDispatchService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Integrations") {
                    ForEach(IntegrationDestination.available, id: \.self) { destination in
                        NavigationLink(value: destination) {
                            integrationRow(for: destination)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .toggleStyle(.smallSwitch)
            .padding(.top, -20)
            .navigationDestination(for: IntegrationDestination.self) { destination in
                integrationDetail(destination)
                    .navigationTitle(destination.displayName)
            }
        }
    }

    private func integrationRow(for destination: IntegrationDestination) -> some View {
        HStack(spacing: 12) {
            integrationIcon(for: destination)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(destination.displayName)
                    .font(.body)
                Text(statusText(for: destination))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func integrationDetail(_ destination: IntegrationDestination) -> some View {
        Form {
            switch destination {
            case .obsidian:
                obsidianDetail
            case .appleNotes:
                appleNotesDetail
            case .appleReminders:
                appleRemindersDetail
            case .notion:
                notionDetail
            case .evernote:
                evernoteDetail
            case .googleKeep:
                googleKeepDetail
            case .oneNote:
                oneNoteDetail
            case .webhook:
                webhookDetail
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
    }

    private var obsidianDetail: some View {
        Section("Configuration") {
            Toggle(isOn: binding({ appSettings.obsidianEnabled }, { appSettings.obsidianEnabled = $0 })) {
                Label("Enable Obsidian", systemImage: "diamond.fill")
            }

            if appSettings.obsidianEnabled {
                LabeledContent("Vault:") {
                    HStack {
                        Text(vaultPathText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose...") {
                            chooseVault { url in appSettings.obsidianVaultURL = url }
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

                Toggle(isOn: binding({ appSettings.obsidianIncludeTranscript }, { appSettings.obsidianIncludeTranscript = $0 })) {
                    Text("Include transcript in notes")
                }
                Text("When off, notes contain only the summary, action items, and tags. Enable to append the full transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appleNotesDetail: some View {
        Section("Configuration") {
            Toggle("Enable Apple Notes", isOn: binding(
                { appSettings.integrations.appleNotes.enabled },
                { appSettings.integrations.appleNotes.enabled = $0 }
            ))

            if appSettings.integrations.appleNotes.enabled {
                TextField("Account name (optional)", text: binding(
                    { appSettings.integrations.appleNotes.accountName },
                    { appSettings.integrations.appleNotes.accountName = $0 }
                ))
                TextField("Folder name (optional)", text: binding(
                    { appSettings.integrations.appleNotes.folderName },
                    { appSettings.integrations.appleNotes.folderName = $0 }
                ))
                deliveryFieldsEditor(
                    title: "Send fields",
                    get: { appSettings.integrations.appleNotes.fields },
                    set: { appSettings.integrations.appleNotes.fields = $0 }
                )
                testButton(for: .appleNotes)
            }
        }
    }

    private var appleRemindersDetail: some View {
        Section("Configuration") {
            Toggle("Enable Apple Reminders", isOn: binding(
                { appSettings.integrations.appleReminders.enabled },
                { appSettings.integrations.appleReminders.enabled = $0 }
            ))

            if appSettings.integrations.appleReminders.enabled {
                TextField("Default list name (optional)", text: binding(
                    { appSettings.integrations.appleReminders.listName },
                    { appSettings.integrations.appleReminders.listName = $0 }
                ))
                Text("Only action items are sent as reminders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                testButton(for: .appleReminders)
            }
        }
    }

    private var notionDetail: some View {
        Section("Configuration") {
            Toggle("Enable Notion", isOn: binding(
                { appSettings.integrations.notion.enabled },
                { appSettings.integrations.notion.enabled = $0 }
            ))

            if appSettings.integrations.notion.enabled {
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
                deliveryFieldsEditor(
                    title: "Send fields",
                    get: { appSettings.integrations.notion.fields },
                    set: { appSettings.integrations.notion.fields = $0 }
                )
                if appSettings.notionToken.isEmpty || appSettings.integrations.notion.parentID.isEmpty {
                    Text("Token and parent ID are required when Notion is enabled.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                testButton(for: .notion)
            }
        }
    }

    private var evernoteDetail: some View {
        Section("Configuration") {
            Toggle("Enable Evernote", isOn: binding(
                { appSettings.integrations.evernote.enabled },
                { appSettings.integrations.evernote.enabled = $0 }
            ))

            if appSettings.integrations.evernote.enabled {
                SecureField("Evernote token", text: binding({ appSettings.evernoteToken }, { appSettings.evernoteToken = $0 }))
                TextField("API base URL", text: binding(
                    { appSettings.integrations.evernote.apiBaseURL },
                    { appSettings.integrations.evernote.apiBaseURL = $0 }
                ))
                TextField("Notebook ID (optional)", text: binding(
                    { appSettings.integrations.evernote.notebookID },
                    { appSettings.integrations.evernote.notebookID = $0 }
                ))
                deliveryFieldsEditor(
                    title: "Send fields",
                    get: { appSettings.integrations.evernote.fields },
                    set: { appSettings.integrations.evernote.fields = $0 }
                )
                if appSettings.evernoteToken.isEmpty {
                    Text("Token is required when Evernote is enabled.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                testButton(for: .evernote)
            }
        }
    }

    private var googleKeepDetail: some View {
        Section("Configuration") {
            Toggle("Enable Google Keep", isOn: binding(
                { appSettings.integrations.googleKeep.enabled },
                { appSettings.integrations.googleKeep.enabled = $0 }
            ))

            if appSettings.integrations.googleKeep.enabled {
                SecureField("Google OAuth token", text: binding({ appSettings.googleKeepToken }, { appSettings.googleKeepToken = $0 }))
                TextField("API base URL", text: binding(
                    { appSettings.integrations.googleKeep.apiBaseURL },
                    { appSettings.integrations.googleKeep.apiBaseURL = $0 }
                ))
                deliveryFieldsEditor(
                    title: "Send fields",
                    get: { appSettings.integrations.googleKeep.fields },
                    set: { appSettings.integrations.googleKeep.fields = $0 }
                )
                Text("Google Keep API is enterprise/admin oriented and may require Workspace setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appSettings.googleKeepToken.isEmpty {
                    Text("Token is required when Google Keep is enabled.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                testButton(for: .googleKeep)
            }
        }
    }

    private var oneNoteDetail: some View {
        Section("Configuration") {
            Toggle("Enable Microsoft OneNote", isOn: binding(
                { appSettings.integrations.oneNote.enabled },
                { appSettings.integrations.oneNote.enabled = $0 }
            ))

            if appSettings.integrations.oneNote.enabled {
                SecureField("Microsoft Graph token", text: binding({ appSettings.oneNoteToken }, { appSettings.oneNoteToken = $0 }))
                TextField("Graph base URL", text: binding(
                    { appSettings.integrations.oneNote.graphBaseURL },
                    { appSettings.integrations.oneNote.graphBaseURL = $0 }
                ))
                TextField("Section ID (optional)", text: binding(
                    { appSettings.integrations.oneNote.sectionID },
                    { appSettings.integrations.oneNote.sectionID = $0 }
                ))
                deliveryFieldsEditor(
                    title: "Send fields",
                    get: { appSettings.integrations.oneNote.fields },
                    set: { appSettings.integrations.oneNote.fields = $0 }
                )
                if appSettings.oneNoteToken.isEmpty {
                    Text("Token is required when OneNote is enabled.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                testButton(for: .oneNote)
            }
        }
    }

    private var webhookDetail: some View {
        Section("Configuration") {
            Toggle("Enable Webhook", isOn: binding(
                { appSettings.integrations.webhook.enabled },
                { appSettings.integrations.webhook.enabled = $0 }
            ))

            if appSettings.integrations.webhook.enabled {
                TextField("Webhook URL", text: binding(
                    { appSettings.integrations.webhook.url },
                    { appSettings.integrations.webhook.url = $0 }
                ))
                HStack {
                    Text("Timeout (seconds)")
                    Spacer()
                    TextField("", value: binding(
                        { appSettings.integrations.webhook.timeoutSeconds },
                        { appSettings.integrations.webhook.timeoutSeconds = $0 }
                    ), format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                }
                HStack {
                    Text("Retries")
                    Spacer()
                    Stepper(value: binding(
                        { appSettings.integrations.webhook.retryCount },
                        { appSettings.integrations.webhook.retryCount = $0 }
                    ), in: 0 ... 5) {
                        Text("\(appSettings.integrations.webhook.retryCount)")
                            .frame(width: 30, alignment: .trailing)
                    }
                    .frame(width: 100)
                }

                Text("Headers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(Array(appSettings.integrations.webhook.headers.enumerated()), id: \.element.id) { index, header in
                    HStack {
                        TextField("Header", text: binding(
                            { headerValue(index: index).key },
                            { updateHeader(index: index, key: $0, value: headerValue(index: index).value) }
                        ))
                        TextField("Value", text: binding(
                            { headerValue(index: index).value },
                            { updateHeader(index: index, key: headerValue(index: index).key, value: $0) }
                        ))
                        Button {
                            removeHeader(id: header.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    appSettings.integrations.webhook.headers.append(WebhookHeader())
                } label: {
                    Label("Add header", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)

                deliveryFieldsEditor(
                    title: "Send fields",
                    get: { appSettings.integrations.webhook.fields },
                    set: { appSettings.integrations.webhook.fields = $0 }
                )

                if appSettings.integrations.webhook.url.isEmpty {
                    Text("Webhook URL is required when webhook is enabled.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                testButton(for: .webhook)
            }
        }
    }

    private func deliveryFieldsEditor(
        title: String,
        get: @escaping () -> [DeliveryField],
        set: @escaping ([DeliveryField]) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(DeliveryField.allCases) { field in
                Toggle(field.displayName, isOn: binding(
                    { get().contains(field) },
                    { isOn in
                        var current = get()
                        if isOn {
                            if !current.contains(field) {
                                current.append(field)
                            }
                        } else {
                            current.removeAll { $0 == field }
                        }
                        set(current)
                    }
                ))
                .toggleStyle(.smallSwitch)
            }
        }
        .padding(.vertical, 4)
    }

    private func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { @MainActor in get() }, set: { @MainActor value in set(value) })
    }

    @ViewBuilder
    private func integrationIcon(for destination: IntegrationDestination) -> some View {
        glassIconTile {
            if let image = integrationIconImage(for: destination) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .scaleEffect(1.15)
            } else {
                Image(systemName: icon(for: destination))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 24, weight: .medium))
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
        case .obsidian:
            return ["Obsidian", destination.rawValue, destination.displayName]
        case .appleNotes:
            return ["Apple Notes", destination.rawValue, destination.displayName]
        case .appleReminders:
            return ["Apple Reminders", destination.rawValue, destination.displayName]
        case .notion:
            return ["Notion", destination.rawValue, destination.displayName]
        case .evernote:
            return ["Evernote", destination.rawValue, destination.displayName]
        case .googleKeep:
            return ["Google Keep", destination.rawValue, destination.displayName]
        case .oneNote:
            return ["OneNote", "Microsoft OneNote", destination.rawValue, destination.displayName]
        case .webhook:
            return ["Webhook", destination.rawValue, destination.displayName]
        }
    }

    private func glassIconTile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.45),
                                    .white.opacity(0.15),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)

            content()
                .padding(3)
        }
    }

    private func icon(for destination: IntegrationDestination) -> String {
        switch destination {
        case .obsidian: "diamond.fill"
        case .appleNotes: "note.text"
        case .appleReminders: "checklist"
        case .notion: "doc.text.fill"
        case .evernote: "leaf.fill"
        case .googleKeep: "lightbulb"
        case .oneNote: "book.closed"
        case .webhook: "network"
        }
    }

    private func statusText(for destination: IntegrationDestination) -> String {
        switch destination {
        case .obsidian:
            return appSettings.obsidianEnabled ? "On" : "Off"
        case .appleNotes:
            return appSettings.integrations.appleNotes.enabled ? "On" : "Off"
        case .appleReminders:
            return appSettings.integrations.appleReminders.enabled ? "On" : "Off"
        case .notion:
            return appSettings.integrations.notion.enabled ? "On" : "Off"
        case .evernote:
            return appSettings.integrations.evernote.enabled ? "On" : "Off"
        case .googleKeep:
            return appSettings.integrations.googleKeep.enabled ? "On" : "Off"
        case .oneNote:
            return appSettings.integrations.oneNote.enabled ? "On" : "Off"
        case .webhook:
            if !appSettings.integrations.webhook.enabled { return "Off" }
            return "On · \(appSettings.integrations.webhook.fields.count) fields"
        }
    }

    private func headerValue(index: Int) -> WebhookHeader {
        guard appSettings.integrations.webhook.headers.indices.contains(index) else {
            return WebhookHeader()
        }
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

    private func testButton(for destination: IntegrationDestination) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task {
                    await runConnectionTest(destination: destination)
                }
            } label: {
                if isTesting.contains(destination) {
                    Text("Testing...")
                } else {
                    Text("Test connection")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isTesting.contains(destination))

            if let message = connectionMessages[destination] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == "Connection successful" ? .green : .red)
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
