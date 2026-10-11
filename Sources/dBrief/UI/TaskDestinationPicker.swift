import SwiftUI

/// Picks a TickTick list or Todoist project, with Inbox (nil) first. Loads the
/// options with the stored sign-in or token, and keeps a saved choice that is
/// missing from them selectable (still loading, or deleted in the service).
/// Shared by Settings → Integrations and the profile overrides.
struct TaskDestinationPicker: View {
    enum Service {
        case tickTick, todoist
    }

    private struct Option: Hashable {
        let id: String
        let name: String
    }

    let service: Service
    let savedID: String?
    let savedName: String?
    let select: (_ id: String?, _ name: String?) -> Void

    @Environment(AppSettings.self) private var appSettings
    @Environment(TickTickAuthService.self) private var tickTickAuth
    @Environment(\.menuPanelPalette) private var status
    @State private var options: [Option] = []
    @State private var error: String?

    private static let inboxTag = "__dbrief_inbox__"

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if error != nil {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.settingsSecondary)
                }
                Picker(service == .tickTick ? "List" : "Project", selection: selection) {
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
        .task(id: reloadKey) { await load() }
    }

    private var selection: Binding<String> {
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

    @MainActor
    private func load() async {
        switch service {
        case .tickTick:
            tickTickAuth.reload()
            guard tickTickAuth.isSignedIn else {
                options = []
                error = TickTickError.notSignedIn.localizedDescription
                return
            }
            do {
                options = try await TickTickClient().listProjects(token: tickTickAuth.accessToken())
                    .map { Option(id: $0.id, name: $0.name) }
                error = nil
            } catch TickTickError.unauthorized {
                TickTickSession.markExpired()
                tickTickAuth.reload()
                error = TickTickError.unauthorized.localizedDescription
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        case .todoist:
            let token = appSettings.todoistToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                options = []
                error = TodoistError.missingToken.localizedDescription
                return
            }
            // The token field updates on every keystroke; wait for typing to settle.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                options = try await TodoistClient().listProjects(token: token).map { Option(id: $0.id, name: $0.name) }
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
