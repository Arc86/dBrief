import SwiftUI

/// A move target for the speaker menu's "Move … to" submenus: another existing speaker.
struct SpeakerMoveTarget: Identifiable, Equatable {
    let id: String          // speakerId
    let displayName: String
}

/// Small popover with a single text field — the typing fallback for naming a speaker whose
/// name isn't among the known suggestions. The common path is selecting a name from the
/// speaker menu; this only appears via "Custom name…".
struct SpeakerRenamePopover: View {
    let currentName: String
    let onRename: (String) -> Void

    @State private var name: String
    @FocusState private var focused: Bool

    init(currentName: String, onRename: @escaping (String) -> Void) {
        self.currentName = currentName
        self.onRename = onRename
        _name = State(initialValue: currentName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RENAME SPEAKER").font(.caption2.bold()).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { commit() }
                Button("Rename") { commit() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 220)
        .onAppear { focused = true }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
    }
}
