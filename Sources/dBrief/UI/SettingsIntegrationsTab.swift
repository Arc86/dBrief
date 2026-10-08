import SwiftUI

struct SettingsIntegrationsTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    let editProfile: (UUID) -> Void
    @State private var connectionMessages: [IntegrationDestination: String] = [:]
    @State private var isTesting: Set<IntegrationDestination> = []
    @State private var openDestination: IntegrationDestination?
    private let integrationService = IntegrationDispatchService()

    var body: some View {
        // In-page detail instead of a NavigationStack: inside the split view a pushed
        // page lands on the window's own navigation stack and stays on screen after
        // switching to another settings page. This state resets with the page.
        SettingsPageScaffold(page: .integrations, notice: {
            VStack(spacing: 10) {
                credentialStorageNotice
                if openDestination == nil {
                    SettingsProfileScopeView(fields: SettingsPage.integrations.profileFields, editProfile: editProfile)
                }
            }
        }) {
            if let destination = openDestination {
                Button {
                    openDestination = nil
                } label: {
                    Label("All integrations", systemImage: "chevron.left")
                }
                .buttonStyle(.settingsSecondary)
                .keyboardShortcut("[", modifiers: .command)
                integrationDetail(destination)
            } else {
                SettingsCard("Send results to", section: .integrations) {
                    ForEach(IntegrationDestination.available, id: \.self) { destination in
                        Button {
                            openDestination = destination
                        } label: {
                            integrationRow(for: destination)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens \(destination.displayName) settings")
                    }
                }
            }
        }
    }

    // MARK: Root rows

    private func integrationRow(for destination: IntegrationDestination) -> some View {
        HStack(spacing: 14) {
            integrationIcon(for: destination)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.displayName)
                    .uiFont(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.heading.color)
                if let summary = summary(for: destination) {
                    Text(summary)
                        .uiFont(.system(size: 11.5))
                        .foregroundStyle(palette.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let state = state(for: destination)
            SettingsStatusPill(LocalizedStringKey(state.title), kind: state.kind)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary.color)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { SettingsHairline() }
    }

    private func isEnabled(_ destination: IntegrationDestination) -> Bool {
        switch destination {
        case .obsidian: appSettings.obsidianEnabled
        case .appleNotes: appSettings.integrations.appleNotes.enabled
        case .appleReminders: appSettings.integrations.appleReminders.enabled
        case .notion: appSettings.integrations.notion.enabled
        case .evernote: appSettings.integrations.evernote.enabled
        case .googleKeep: appSettings.integrations.googleKeep.enabled
        case .oneNote: appSettings.integrations.oneNote.enabled
        case .webhook: appSettings.integrations.webhook.enabled
        }
    }

    /// Required fields missing while enabled (the same conditions the detail pages warn about).
    private func needsSetup(_ destination: IntegrationDestination) -> Bool {
        switch destination {
        case .obsidian: appSettings.obsidianVaultURL == nil
        case .appleNotes, .appleReminders: false
        case .notion: appSettings.notionToken.isEmpty || appSettings.integrations.notion.parentID.isEmpty
        case .evernote: appSettings.evernoteToken.isEmpty
        case .googleKeep: appSettings.googleKeepToken.isEmpty
        case .oneNote: appSettings.oneNoteToken.isEmpty
        case .webhook: appSettings.integrations.webhook.url.isEmpty
        }
    }

    private func state(for destination: IntegrationDestination) -> (title: String, kind: SettingsStatusPill.Kind) {
        guard isEnabled(destination) else { return ("Off", .neutral) }
        return needsSetup(destination) ? ("Needs setup", .warning) : ("On", .success)
    }

    private func summary(for destination: IntegrationDestination) -> String? {
        guard isEnabled(destination) else { return nil }
        switch destination {
        case .obsidian:
            guard let vault = appSettings.obsidianVaultURL else { return "Choose a vault" }
            return "\(vault.lastPathComponent) · \(appSettings.obsidianFolderDisplayName(relativePath: appSettings.obsidianDefaultFolderRelativePath))"
        case .appleNotes:
            let folder = appSettings.integrations.appleNotes.folderName
            return folder.isEmpty ? "Default folder" : "Folder “\(folder)”"
        case .appleReminders:
            let list = appSettings.integrations.appleReminders.listName
            return "One reminder per action item · " + (list.isEmpty ? "default list" : "list “\(list)”")
        case .webhook:
            let host = URLComponents(string: appSettings.integrations.webhook.url)?.host
            return host.map { "\($0) · \(appSettings.integrations.webhook.fields.count) fields" } ?? "Add a URL"
        case .notion, .evernote, .googleKeep, .oneNote:
            return nil
        }
    }

    @ViewBuilder
    private func integrationIcon(for destination: IntegrationDestination) -> some View {
        if let image = integrationIconImage(for: destination) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: icon(for: destination))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.heading.color)
                .frame(width: 28, height: 28)
                .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.divider.color, lineWidth: 1) }
        }
    }

    // MARK: Detail pages

    @ViewBuilder
    private func integrationDetail(_ destination: IntegrationDestination) -> some View {
        switch destination {
        case .obsidian: obsidianDetail
        case .appleNotes: appleNotesDetail
        case .appleReminders: appleRemindersDetail
        case .notion: notionDetail
        case .evernote: evernoteDetail
        case .googleKeep: googleKeepDetail
        case .oneNote: oneNoteDetail
        case .webhook: webhookDetail
        }
    }

    private func enableRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        SettingsRow(verbatim: title) { Toggle(title, isOn: isOn) }
    }

    private func textRow(_ label: String, optional: Bool = false, secure: Bool = false,
                         _ text: Binding<String>) -> some View {
        SettingsRow(verbatim: label, caption: optional ? "Optional" : nil) {
            Group {
                if secure {
                    SecureField(label, text: text)
                } else {
                    TextField(label, text: text)
                }
            }
            .settingsTextField()
            .frame(width: 260)
        }
    }

    private func warningRow(_ text: String) -> some View {
        SettingsRow(verbatim: text) { SettingsStatusPill("Needs setup", kind: .warning) }
    }

    private var obsidianDetail: some View {
        SettingsCard("Obsidian") {
            enableRow("Send to Obsidian", binding({ appSettings.obsidianEnabled }, { appSettings.obsidianEnabled = $0 }))
            if appSettings.obsidianEnabled {
                SettingsRow(verbatim: "Vault", caption: vaultPathText, systemImage: "folder") {
                    Button("Choose…") { chooseVault { url in appSettings.obsidianVaultURL = url } }
                        .buttonStyle(.settingsSecondary)
                }
                SettingsRow(verbatim: "Default folder",
                            caption: appSettings.obsidianVaultURL == nil
                                ? "Choose a vault first."
                                : appSettings.obsidianFolderDisplayName(relativePath: appSettings.obsidianDefaultFolderRelativePath),
                            systemImage: "folder") {
                    Button("Choose…") {
                        chooseFolderInVault { relativePath in appSettings.obsidianDefaultFolderRelativePath = relativePath }
                    }
                    .buttonStyle(.settingsSecondary)
                    .disabled(appSettings.obsidianVaultURL == nil)
                }
                SettingsRow("Include the transcript", caption: "Off sends only the summary, action items and tags.") {
                    Toggle("Include the transcript", isOn: binding({ appSettings.obsidianIncludeTranscript },
                                                                   { appSettings.obsidianIncludeTranscript = $0 }))
                }
            }
        }
    }

    @ViewBuilder
    private var appleNotesDetail: some View {
        SettingsCard("Apple Notes") {
            enableRow("Send to Apple Notes", binding({ appSettings.integrations.appleNotes.enabled },
                                                     { appSettings.integrations.appleNotes.enabled = $0 }))
            if appSettings.integrations.appleNotes.enabled {
                textRow("Account name", optional: true, binding({ appSettings.integrations.appleNotes.accountName },
                                                                { appSettings.integrations.appleNotes.accountName = $0 }))
                textRow("Folder name", optional: true, binding({ appSettings.integrations.appleNotes.folderName },
                                                               { appSettings.integrations.appleNotes.folderName = $0 }))
                testRow(for: .appleNotes)
            }
        }
        if appSettings.integrations.appleNotes.enabled {
            deliveryFieldsCard(get: { appSettings.integrations.appleNotes.fields },
                               set: { appSettings.integrations.appleNotes.fields = $0 })
        }
    }

    private var appleRemindersDetail: some View {
        SettingsCard("Apple Reminders", description: "Only action items are sent, one reminder each") {
            enableRow("Send to Apple Reminders", binding({ appSettings.integrations.appleReminders.enabled },
                                                         { appSettings.integrations.appleReminders.enabled = $0 }))
            if appSettings.integrations.appleReminders.enabled {
                textRow("Default list", optional: true, binding({ appSettings.integrations.appleReminders.listName },
                                                                { appSettings.integrations.appleReminders.listName = $0 }))
                testRow(for: .appleReminders)
            }
        }
    }

    @ViewBuilder
    private var notionDetail: some View {
        SettingsCard("Notion") {
            enableRow("Send to Notion", binding({ appSettings.integrations.notion.enabled },
                                                { appSettings.integrations.notion.enabled = $0 }))
            if appSettings.integrations.notion.enabled {
                textRow("Token", secure: true, binding({ appSettings.notionToken }, { appSettings.notionToken = $0 }))
                SettingsRow("Parent type") {
                    Picker("Parent type", selection: binding({ appSettings.integrations.notion.parentType },
                                                             { appSettings.integrations.notion.parentType = $0 })) {
                        Text("Data source").tag(NotionParentType.dataSource)
                        Text("Page").tag(NotionParentType.page)
                    }
                    .pickerStyle(.menu)
                }
                textRow("Parent ID", binding({ appSettings.integrations.notion.parentID },
                                             { appSettings.integrations.notion.parentID = $0 }))
                textRow("Title property", binding({ appSettings.integrations.notion.titlePropertyName },
                                                  { appSettings.integrations.notion.titlePropertyName = $0 }))
                if appSettings.notionToken.isEmpty || appSettings.integrations.notion.parentID.isEmpty {
                    warningRow("Token and parent ID are required.")
                }
                testRow(for: .notion)
            }
        }
        if appSettings.integrations.notion.enabled {
            deliveryFieldsCard(get: { appSettings.integrations.notion.fields },
                               set: { appSettings.integrations.notion.fields = $0 })
        }
    }

    @ViewBuilder
    private var evernoteDetail: some View {
        SettingsCard("Evernote") {
            enableRow("Send to Evernote", binding({ appSettings.integrations.evernote.enabled },
                                                  { appSettings.integrations.evernote.enabled = $0 }))
            if appSettings.integrations.evernote.enabled {
                textRow("Token", secure: true, binding({ appSettings.evernoteToken }, { appSettings.evernoteToken = $0 }))
                textRow("API base URL", binding({ appSettings.integrations.evernote.apiBaseURL },
                                                { appSettings.integrations.evernote.apiBaseURL = $0 }))
                textRow("Notebook ID", optional: true, binding({ appSettings.integrations.evernote.notebookID },
                                                               { appSettings.integrations.evernote.notebookID = $0 }))
                if appSettings.evernoteToken.isEmpty { warningRow("A token is required.") }
                testRow(for: .evernote)
            }
        }
        if appSettings.integrations.evernote.enabled {
            deliveryFieldsCard(get: { appSettings.integrations.evernote.fields },
                               set: { appSettings.integrations.evernote.fields = $0 })
        }
    }

    @ViewBuilder
    private var googleKeepDetail: some View {
        SettingsCard("Google Keep", description: "The Keep API may need Google Workspace setup") {
            enableRow("Send to Google Keep", binding({ appSettings.integrations.googleKeep.enabled },
                                                     { appSettings.integrations.googleKeep.enabled = $0 }))
            if appSettings.integrations.googleKeep.enabled {
                textRow("OAuth token", secure: true, binding({ appSettings.googleKeepToken }, { appSettings.googleKeepToken = $0 }))
                textRow("API base URL", binding({ appSettings.integrations.googleKeep.apiBaseURL },
                                                { appSettings.integrations.googleKeep.apiBaseURL = $0 }))
                if appSettings.googleKeepToken.isEmpty { warningRow("A token is required.") }
                testRow(for: .googleKeep)
            }
        }
        if appSettings.integrations.googleKeep.enabled {
            deliveryFieldsCard(get: { appSettings.integrations.googleKeep.fields },
                               set: { appSettings.integrations.googleKeep.fields = $0 })
        }
    }

    @ViewBuilder
    private var oneNoteDetail: some View {
        SettingsCard("Microsoft OneNote") {
            enableRow("Send to OneNote", binding({ appSettings.integrations.oneNote.enabled },
                                                 { appSettings.integrations.oneNote.enabled = $0 }))
            if appSettings.integrations.oneNote.enabled {
                textRow("Graph token", secure: true, binding({ appSettings.oneNoteToken }, { appSettings.oneNoteToken = $0 }))
                textRow("Graph base URL", binding({ appSettings.integrations.oneNote.graphBaseURL },
                                                  { appSettings.integrations.oneNote.graphBaseURL = $0 }))
                textRow("Section ID", optional: true, binding({ appSettings.integrations.oneNote.sectionID },
                                                              { appSettings.integrations.oneNote.sectionID = $0 }))
                if appSettings.oneNoteToken.isEmpty { warningRow("A token is required.") }
                testRow(for: .oneNote)
            }
        }
        if appSettings.integrations.oneNote.enabled {
            deliveryFieldsCard(get: { appSettings.integrations.oneNote.fields },
                               set: { appSettings.integrations.oneNote.fields = $0 })
        }
    }

    @ViewBuilder
    private var credentialStorageNotice: some View {
        if let message = appSettings.integrationPersistenceError {
            SettingsNotice(Text(message), tone: .warning) {
                Button("Retry") { appSettings.retryIntegrationCredentialStorage() }
                    .buttonStyle(.settingsSecondary)
            }
        }
    }

    @ViewBuilder
    private var webhookDetail: some View {
        Group {
            SettingsCard("Webhook",
                         description: "Each delivery has an Idempotency-Key; retry unconfirmed sends from History") {
                enableRow("Send to a webhook", binding({ appSettings.integrations.webhook.enabled },
                                                       { appSettings.integrations.webhook.enabled = $0 }))
                if appSettings.integrations.webhook.enabled {
                    textRow("URL", secure: true, binding({ appSettings.integrations.webhook.url },
                                                         { appSettings.integrations.webhook.url = $0 }))
                    SettingsRow("Timeout") {
                        HStack(spacing: 6) {
                            TextField("Timeout", value: binding({ appSettings.integrations.webhook.timeoutSeconds },
                                                                { appSettings.integrations.webhook.timeoutSeconds = $0 }),
                                      format: .number)
                                .settingsTextField()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("seconds").uiFont(.system(size: 12)).foregroundStyle(palette.secondary.color)
                        }
                    }
                    if appSettings.integrations.webhook.url.isEmpty { warningRow("A URL is required.") }
                    testRow(for: .webhook)
                }
            }
            if appSettings.integrations.webhook.enabled {
                SettingsCard("Headers") {
                    ForEach(Array(appSettings.integrations.webhook.headers.enumerated()), id: \.element.id) { index, header in
                        SettingsStackedRow {
                            HStack(spacing: 8) {
                                TextField("Header", text: binding(
                                    { headerValue(index: index).key },
                                    { updateHeader(index: index, key: $0, value: headerValue(index: index).value) }
                                ))
                                .settingsTextField()
                                SecureField("Value", text: binding(
                                    { headerValue(index: index).value },
                                    { updateHeader(index: index, key: headerValue(index: index).key, value: $0) }
                                ))
                                .settingsTextField()
                                Button { removeHeader(id: header.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.settingsSecondary)
                                    .accessibilityLabel("Remove header")
                            }
                        }
                    }
                    SettingsRow("Add a header") {
                        Button {
                            appSettings.integrations.webhook.headers.append(WebhookHeader())
                        } label: {
                            Label("Add header", systemImage: "plus")
                        }
                        .buttonStyle(.settingsSecondary)
                    }
                }
                deliveryFieldsCard(get: { appSettings.integrations.webhook.fields },
                                   set: { appSettings.integrations.webhook.fields = $0 })
            }
        }
        .disabled(appSettings.integrations.webhook.credentialsUnavailable)
    }

    private func deliveryFieldsCard(get: @escaping () -> [DeliveryField],
                                    set: @escaping ([DeliveryField]) -> Void) -> some View {
        SettingsCard("Send fields") {
            ForEach(DeliveryField.allCases) { field in
                SettingsRow(verbatim: field.displayName) {
                    Toggle(field.displayName, isOn: binding(
                        { get().contains(field) },
                        { isOn in
                            var current = get()
                            if isOn {
                                if !current.contains(field) { current.append(field) }
                            } else {
                                current.removeAll { $0 == field }
                            }
                            set(current)
                        }
                    ))
                }
            }
        }
    }

    private func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { @MainActor in get() }, set: { @MainActor value in set(value) })
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

    @ViewBuilder
    private func testRow(for destination: IntegrationDestination) -> some View {
        let message = connectionMessages[destination]
        SettingsRow("Test the connection") {
            HStack(spacing: 8) {
                if let message {
                    if message == "Connection successful" {
                        SettingsStatusPill("Connected", kind: .success)
                    } else {
                        SettingsStatusPill("Failed", kind: .danger).help(message)
                    }
                }
                Button(isTesting.contains(destination) ? "Testing…" : "Test connection") {
                    Task { await runConnectionTest(destination: destination) }
                }
                .buttonStyle(.settingsSecondary)
                .disabled(isTesting.contains(destination))
            }
        }
        if let message, message != "Connection successful" {
            SettingsStackedRow {
                Text(message)
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(status.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
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
