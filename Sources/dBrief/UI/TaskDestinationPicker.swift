import SwiftUI

/// TickTick lists and Todoist projects, loaded once per credential and shared by
/// every picker. A menu picker sizes itself to its longest item, so a picker
/// that appears before its items load visibly widens a moment later; with the
/// options already here it draws at its final width straight away.
@MainActor
@Observable
final class TaskDestinationCatalog {
    static let shared = TaskDestinationCatalog()

    struct Option: Hashable, Sendable {
        let id: String
        let name: String
    }

    private var optionsByService: [TaskDestinationPicker.Service: [Option]] = [:]
    private var errorsByService: [TaskDestinationPicker.Service: String] = [:]
    @ObservationIgnored private var loadedKeys: [TaskDestinationPicker.Service: String] = [:]

    func options(for service: TaskDestinationPicker.Service) -> [Option] { optionsByService[service] ?? [] }
    func error(for service: TaskDestinationPicker.Service) -> String? { errorsByService[service] }

    /// Fetches unless options for this credential (`key`) are already loaded.
    func load(_ service: TaskDestinationPicker.Service, key: String, force: Bool = false,
              fetch: () async throws -> [Option]) async {
        guard force || loadedKeys[service] != key || errorsByService[service] != nil else { return }
        do {
            let options = try await fetch()
            optionsByService[service] = options
            errorsByService[service] = nil
            loadedKeys[service] = key
        } catch is CancellationError {
        } catch {
            errorsByService[service] = error.localizedDescription
            loadedKeys[service] = key
        }
    }

    /// No usable credential: forget the options and show why.
    func clear(_ service: TaskDestinationPicker.Service, message: String) {
        optionsByService[service] = []
        errorsByService[service] = message
        loadedKeys[service] = nil
    }
}

/// Picks a TickTick list or Todoist project, with Inbox (nil) first. Options
/// come from `TaskDestinationCatalog`; a saved choice missing from them stays
/// selectable (still loading, or deleted in the service). Shared by Settings →
/// Integrations and the profile overrides.
struct TaskDestinationPicker: View {
    enum Service: Hashable, Sendable {
        case tickTick, todoist
    }

    let service: Service
    let savedID: String?
    let savedName: String?
    let select: (_ id: String?, _ name: String?) -> Void

    @Environment(AppSettings.self) private var appSettings
    @Environment(TickTickAuthService.self) private var tickTickAuth
    @Environment(\.menuPanelPalette) private var status

    private static let inboxTag = "__dbrief_inbox__"
    private var catalog: TaskDestinationCatalog { .shared }

    var body: some View {
        let options = catalog.options(for: service)
        let error = catalog.error(for: service)
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if error != nil {
                    Button("Retry") {
                        Task { await Self.load(service, appSettings: appSettings, tickTickAuth: tickTickAuth, force: true) }
                    }
                    .buttonStyle(.settingsSecondary)
                }
                Picker(service == .tickTick ? "List" : "Project", selection: selection(options)) {
                    Text("Inbox").tag(Self.inboxTag)
                    ForEach(options, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                    if let savedID, !options.contains(where: { $0.id == savedID }) {
                        Text(savedName ?? "Unavailable list").tag(savedID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
            if let error {
                Text(error)
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(status.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: reloadKey) {
            await Self.load(service, appSettings: appSettings, tickTickAuth: tickTickAuth, debounce: true)
        }
    }

    private func selection(_ options: [TaskDestinationCatalog.Option]) -> Binding<String> {
        Binding(
            get: { savedID ?? Self.inboxTag },
            set: { id in
                guard id != Self.inboxTag else { return select(nil, nil) }
                select(id, options.first(where: { $0.id == id })?.name ?? savedName)
            })
    }

    /// Reload when the credential changes (sign-in, sign-out, a pasted token).
    private var reloadKey: String {
        switch service {
        case .tickTick: tickTickAuth.isSignedIn ? "signed-in" : "signed-out"
        case .todoist: appSettings.todoistToken
        }
    }

    /// Loads the lists for every connected service, so pickers opened later in
    /// this Settings session already have them. Called when Settings appears.
    static func prefetch(appSettings: AppSettings, tickTickAuth: TickTickAuthService) async {
        if IntegrationDestination.available.contains(.tickTick) {
            await load(.tickTick, appSettings: appSettings, tickTickAuth: tickTickAuth)
        }
        await load(.todoist, appSettings: appSettings, tickTickAuth: tickTickAuth)
    }

    /// `debounce` waits for a token being typed to settle before fetching.
    static func load(_ service: Service, appSettings: AppSettings, tickTickAuth: TickTickAuthService,
                     force: Bool = false, debounce: Bool = false) async {
        let catalog = TaskDestinationCatalog.shared
        switch service {
        case .tickTick:
            tickTickAuth.reload()
            guard tickTickAuth.isSignedIn, let token = try? tickTickAuth.accessToken() else {
                return catalog.clear(.tickTick, message: TickTickError.notSignedIn.localizedDescription)
            }
            await catalog.load(.tickTick, key: token, force: force) {
                do {
                    return try await TickTickClient().listProjects(token: token).map { .init(id: $0.id, name: $0.name) }
                } catch TickTickError.unauthorized {
                    TickTickSession.markExpired()
                    tickTickAuth.reload()
                    throw TickTickError.unauthorized
                }
            }
        case .todoist:
            let token = appSettings.todoistToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                return catalog.clear(.todoist, message: TodoistError.missingToken.localizedDescription)
            }
            await catalog.load(.todoist, key: token, force: force) {
                if debounce { try await Task.sleep(for: .milliseconds(600)) }
                return try await TodoistClient().listProjects(token: token).map { .init(id: $0.id, name: $0.name) }
            }
        }
    }
}
