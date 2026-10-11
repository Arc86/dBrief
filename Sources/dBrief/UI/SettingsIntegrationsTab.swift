import SwiftUI

struct SettingsIntegrationsTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    let editProfile: (UUID) -> Void
    @State private var testOutcomes: [IntegrationDestination: TestOutcome] = [:]
    @State private var isTesting: Set<IntegrationDestination> = []
    @State private var openDestination: IntegrationDestination?
    @Environment(TickTickAuthService.self) private var tickTickAuth
    @State private var tickTickSignInError: String?

    private enum TestOutcome: Equatable {
        case success
        case failure(String)
    }

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
                    // A result from this visit may not hold after later edits.
                    testOutcomes[destination] = nil
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
        .onAppear { tickTickAuth.reload() }
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
        case .tickTick: appSettings.integrations.tickTick.enabled
        case .todoist: appSettings.integrations.todoist.enabled
        }
    }

    /// Required fields missing while enabled (the same conditions the detail pages warn about).
    private func needsSetup(_ destination: IntegrationDestination) -> Bool {
        switch destination {
        case .obsidian: appSettings.obsidianVaultURL == nil
        case .appleNotes, .appleReminders: false
        case .tickTick: !tickTickAuth.isSignedIn
        case .todoist: appSettings.todoistToken.isEmpty
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
        case .tickTick:
            return "One task per action item · list “\(appSettings.integrations.tickTick.projectName ?? "Inbox")”"
        case .todoist:
            return "One task per action item · project “\(appSettings.integrations.todoist.projectName ?? "Inbox")”"
        case .notion:
            let notion = appSettings.integrations.notion
            guard !notion.parentID.isEmpty else { return "Choose a page or database" }
            return "\(notion.parentType == .dataSource ? "Database" : "Page") “\(notion.parentName ?? "Untitled")”"
        case .evernote, .googleKeep, .oneNote:
            return nil
        }
    }

    @ViewBuilder
    private func integrationIcon(for destination: IntegrationDestination) -> some View {
        if let image = Self.iconImages[destination] {
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
        case .tickTick: tickTickDetail
        case .todoist: todoistDetail
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

    @ViewBuilder
    private var obsidianDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("Obsidian") {
            enableRow("Send to Obsidian", $settings.obsidianEnabled)
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
                    Toggle("Include the transcript", isOn: $settings.obsidianIncludeTranscript)
                }
            }
        }
    }

    @ViewBuilder
    private var appleNotesDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("Apple Notes") {
            enableRow("Send to Apple Notes", $settings.integrations.appleNotes.enabled)
            if appSettings.integrations.appleNotes.enabled {
                textRow("Account name", optional: true, $settings.integrations.appleNotes.accountName)
                textRow("Folder name", optional: true, $settings.integrations.appleNotes.folderName)
                testRow(for: .appleNotes)
            }
        }
        if appSettings.integrations.appleNotes.enabled {
            deliveryFieldsCard($settings.integrations.appleNotes.fields)
        }
    }

    @ViewBuilder
    private var appleRemindersDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("Apple Reminders", description: "Only action items are sent, one reminder each") {
            enableRow("Send to Apple Reminders", $settings.integrations.appleReminders.enabled)
            if appSettings.integrations.appleReminders.enabled {
                textRow("Default list", optional: true, $settings.integrations.appleReminders.listName)
                testRow(for: .appleReminders)
            }
        }
    }

    @ViewBuilder
    private var tickTickDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("TickTick", description: "Only action items are sent, one task each") {
            enableRow("Send to TickTick", $settings.integrations.tickTick.enabled)
            if appSettings.integrations.tickTick.enabled {
                tickTickAccountRow
                if tickTickAuth.isSignedIn {
                    tickTickListRow
                    testRow(for: .tickTick)
                }
            }
        }
    }

    @ViewBuilder
    private var tickTickAccountRow: some View {
        if tickTickAuth.isSignedIn {
            SettingsRow(verbatim: "TickTick account", caption: "Connected", systemImage: "person.crop.circle") {
                Button("Sign out") { Task { await tickTickAuth.signOut() } }
                    .buttonStyle(.settingsSecondary)
            }
        } else {
            SettingsRow(verbatim: "TickTick account",
                        caption: tickTickAuth.isSigningIn
                            ? "Finish signing in in your browser."
                            : tickTickSignInError
                                ?? (tickTickAuth.sessionExpired ? "Your TickTick sign-in expired. Sign in again." : "Not connected"),
                        systemImage: "person.crop.circle") {
                if tickTickAuth.isSigningIn {
                    Button("Cancel") { tickTickAuth.cancelSignIn() }
                        .buttonStyle(.settingsSecondary)
                } else {
                    Button("Sign in with TickTick") {
                        Task { await signInToTickTick() }
                    }
                    .buttonStyle(.settingsPrimary)
                }
            }
        }
    }

    private var tickTickListRow: some View {
        let saved = appSettings.integrations.tickTick
        return SettingsRow(verbatim: "List", systemImage: "list.bullet") {
            TaskDestinationPicker(service: .tickTick, savedID: saved.projectID, savedName: saved.projectName) { id, name in
                var config = appSettings.integrations.tickTick
                config.projectID = id
                config.projectName = name
                appSettings.integrations.tickTick = config
            }
        }
    }

    @ViewBuilder
    private var todoistDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("Todoist", description: "Only action items are sent, one task each") {
            enableRow("Send to Todoist", $settings.integrations.todoist.enabled)
            if appSettings.integrations.todoist.enabled {
                textRow("API token", secure: true, $settings.todoistToken)
                SettingsRow(verbatim: "Where to find it", caption: "Todoist → Settings → Integrations → Developer") {
                    Button("Open Todoist") { NSWorkspace.shared.open(TodoistAPI.tokenSettingsURL) }
                        .buttonStyle(.settingsSecondary)
                }
                if appSettings.todoistToken.isEmpty {
                    warningRow("An API token is required.")
                } else {
                    todoistProjectRow
                    testRow(for: .todoist)
                }
            }
        }
    }

    private var todoistProjectRow: some View {
        let saved = appSettings.integrations.todoist
        return SettingsRow(verbatim: "Project", systemImage: "list.bullet") {
            TaskDestinationPicker(service: .todoist, savedID: saved.projectID, savedName: saved.projectName) { id, name in
                var config = appSettings.integrations.todoist
                config.projectID = id
                config.projectName = name
                appSettings.integrations.todoist = config
            }
        }
    }

    @MainActor
    private func signInToTickTick() async {
        tickTickSignInError = nil
        do {
            try await tickTickAuth.signIn()
        } catch {
            tickTickSignInError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var notionDetail: some View {
        @Bindable var settings = appSettings
        let notion = appSettings.integrations.notion
        SettingsCard("Notion", description: "One page per meeting, under a page or in a database") {
            enableRow("Send to Notion", $settings.integrations.notion.enabled)
            if notion.enabled {
                textRow("Integration secret", secure: true, $settings.notionToken)
                SettingsRow(verbatim: "Where to get it",
                            caption: "Create an internal integration, then connect your page or database to it (••• → Connections).") {
                    Button("Open Notion") { NSWorkspace.shared.open(NotionAPI.integrationsURL) }
                        .buttonStyle(.settingsSecondary)
                }
                if appSettings.notionToken.isEmpty {
                    warningRow("An integration secret is required.")
                } else {
                    SettingsRow(verbatim: "Destination", caption: "Pages and databases connected to the integration",
                                systemImage: "doc.text") {
                        TaskDestinationPicker(
                            service: .notion,
                            savedID: notion.parentID.isEmpty ? nil : TaskDestinationPicker.notionTag(notion.parentType, notion.parentID),
                            savedName: notion.parentName) { tag, name in
                            var config = appSettings.integrations.notion
                            let destination = tag.flatMap(TaskDestinationPicker.notionDestination(fromTag:))
                            config.parentID = destination?.id ?? ""
                            config.parentType = destination?.type ?? .page
                            config.parentName = destination == nil ? nil : name
                            appSettings.integrations.notion = config
                        }
                    }
                    if notion.parentID.isEmpty { warningRow("Choose a page or database.") }
                    testRow(for: .notion)
                }
            }
        }
        if notion.enabled {
            deliveryFieldsCard($settings.integrations.notion.fields)
        }
    }

    @ViewBuilder
    private var evernoteDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("Evernote") {
            enableRow("Send to Evernote", $settings.integrations.evernote.enabled)
            if appSettings.integrations.evernote.enabled {
                textRow("Token", secure: true, $settings.evernoteToken)
                textRow("API base URL", $settings.integrations.evernote.apiBaseURL)
                textRow("Notebook ID", optional: true, $settings.integrations.evernote.notebookID)
                if appSettings.evernoteToken.isEmpty { warningRow("A token is required.") }
                testRow(for: .evernote)
            }
        }
        if appSettings.integrations.evernote.enabled {
            deliveryFieldsCard($settings.integrations.evernote.fields)
        }
    }

    @ViewBuilder
    private var googleKeepDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("Google Keep", description: "The Keep API may need Google Workspace setup") {
            enableRow("Send to Google Keep", $settings.integrations.googleKeep.enabled)
            if appSettings.integrations.googleKeep.enabled {
                textRow("OAuth token", secure: true, $settings.googleKeepToken)
                textRow("API base URL", $settings.integrations.googleKeep.apiBaseURL)
                if appSettings.googleKeepToken.isEmpty { warningRow("A token is required.") }
                testRow(for: .googleKeep)
            }
        }
        if appSettings.integrations.googleKeep.enabled {
            deliveryFieldsCard($settings.integrations.googleKeep.fields)
        }
    }

    @ViewBuilder
    private var oneNoteDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("Microsoft OneNote") {
            enableRow("Send to OneNote", $settings.integrations.oneNote.enabled)
            if appSettings.integrations.oneNote.enabled {
                textRow("Graph token", secure: true, $settings.oneNoteToken)
                textRow("Graph base URL", $settings.integrations.oneNote.graphBaseURL)
                textRow("Section ID", optional: true, $settings.integrations.oneNote.sectionID)
                if appSettings.oneNoteToken.isEmpty { warningRow("A token is required.") }
                testRow(for: .oneNote)
            }
        }
        if appSettings.integrations.oneNote.enabled {
            deliveryFieldsCard($settings.integrations.oneNote.fields)
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
        @Bindable var settings = appSettings
        Group {
            SettingsCard("Webhook",
                         description: "Each delivery has an Idempotency-Key; retry unconfirmed sends from History") {
                enableRow("Send to a webhook", $settings.integrations.webhook.enabled)
                if appSettings.integrations.webhook.enabled {
                    textRow("URL", secure: true, $settings.integrations.webhook.url)
                    SettingsRow("Timeout") {
                        HStack(spacing: 6) {
                            TextField("Timeout", value: $settings.integrations.webhook.timeoutSeconds,
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
                    ForEach($settings.integrations.webhook.headers) { $header in
                        SettingsStackedRow {
                            HStack(spacing: 8) {
                                TextField("Header", text: $header.key)
                                    .settingsTextField()
                                SecureField("Value", text: $header.value)
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
                deliveryFieldsCard($settings.integrations.webhook.fields, includingAudio: true)
            }
        }
        .disabled(appSettings.integrations.webhook.credentialsUnavailable)
    }

    private func deliveryFieldsCard(_ fields: Binding<[DeliveryField]>, includingAudio: Bool = false) -> some View {
        SettingsCard("Send fields") {
            ForEach(DeliveryField.options(includingAudio: includingAudio)) { field in
                SettingsRow(verbatim: field.displayName) {
                    Toggle(field.displayName, isOn: fields[contains: field])
                }
            }
        }
    }

    /// Bundled brand icons, resolved once: the first match in name, then extension, order.
    private static let iconImages: [IntegrationDestination: NSImage] = {
        guard let resourceURL = Bundle.main.resourceURL else { return [:] }
        let extensions = ["png", "jpg", "jpeg", "pdf", "icns", "webp", ""]
        var images: [IntegrationDestination: NSImage] = [:]
        for destination in IntegrationDestination.allCases {
            var seen = Set<String>()
            let names = iconFileBaseNames(for: destination).flatMap { [$0, $0.lowercased()] }
                .filter { seen.insert($0).inserted }
            search: for name in names {
                for ext in extensions {
                    let fileName = ext.isEmpty ? name : "\(name).\(ext)"
                    if let image = NSImage(contentsOf: resourceURL.appendingPathComponent("3dPartyIcons/\(fileName)")) {
                        images[destination] = image
                        break search
                    }
                }
            }
        }
        return images
    }()

    private static func iconFileBaseNames(for destination: IntegrationDestination) -> [String] {
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
        case .tickTick:
            return ["TickTick", destination.rawValue, destination.displayName]
        case .todoist:
            return ["Todoist", destination.rawValue, destination.displayName]
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
        case .tickTick: "checkmark.square"
        case .todoist: "checkmark.circle"
        }
    }

    private func removeHeader(id: UUID) {
        appSettings.integrations.webhook.headers.removeAll { $0.id == id }
    }

    @ViewBuilder
    private func testRow(for destination: IntegrationDestination) -> some View {
        let outcome = testOutcomes[destination]
        SettingsRow("Test the connection") {
            HStack(spacing: 8) {
                switch outcome {
                case .success: SettingsStatusPill("Connected", kind: .success)
                case .failure(let message): SettingsStatusPill("Failed", kind: .danger).help(message)
                case nil: EmptyView()
                }
                Button(isTesting.contains(destination) ? "Testing…" : "Test connection") {
                    Task { await runConnectionTest(destination: destination) }
                }
                .buttonStyle(.settingsSecondary)
                .disabled(isTesting.contains(destination))
            }
        }
        if case .failure(let message) = outcome {
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
            // Created per test: the service owns an EKEventStore, too costly for view init.
            try await IntegrationDispatchService().testConnection(destination: destination, settings: appSettings)
            testOutcomes[destination] = .success
        } catch {
            testOutcomes[destination] = .failure(error.localizedDescription)
        }
        if destination == .tickTick { tickTickAuth.reload() }
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

private extension Array where Element == DeliveryField {
    /// Membership as a settable flag, for key-path toggle bindings.
    subscript(contains field: DeliveryField) -> Bool {
        get { contains(field) }
        set {
            if newValue {
                if !contains(field) { append(field) }
            } else {
                removeAll { $0 == field }
            }
        }
    }
}
