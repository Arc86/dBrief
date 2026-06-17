import SwiftUI

/// A move target for the "Move this turn to" section: another existing speaker.
struct SpeakerMoveTarget: Identifiable, Equatable {
    let id: String          // speakerId
    let displayName: String
}

/// Popover body for the speaker badge. Two independent actions:
///  • **Rename** the current speaker (free text or a known-name suggestion). Applies to the
///    whole speaker; if the name already belongs to another speaker the two swap names
///    (handled upstream by `SpeakerReassignment.rename`).
///  • **Move this turn to** another existing speaker — with a This turn / All scope step.
struct SpeakerAssignPicker: View {
    let currentDisplayName: String
    let nameSuggestions: [String]
    let otherSpeakers: [SpeakerMoveTarget]
    let speakerSegmentCount: Int
    let turnSegmentCount: Int
    let onRename: (String) -> Void
    let onReassign: (_ toSpeakerId: String, _ scope: ReassignScope) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var pendingTargetId: String?
    @FocusState private var nameFocused: Bool

    init(currentDisplayName: String,
         nameSuggestions: [String],
         otherSpeakers: [SpeakerMoveTarget],
         speakerSegmentCount: Int,
         turnSegmentCount: Int,
         onRename: @escaping (String) -> Void,
         onReassign: @escaping (String, ReassignScope) -> Void,
         onCancel: @escaping () -> Void) {
        self.currentDisplayName = currentDisplayName
        self.nameSuggestions = nameSuggestions
        self.otherSpeakers = otherSpeakers
        self.speakerSegmentCount = speakerSegmentCount
        self.turnSegmentCount = turnSegmentCount
        self.onRename = onRename
        self.onReassign = onReassign
        self.onCancel = onCancel
        _name = State(initialValue: currentDisplayName)
    }

    private var hasSegmentsBeyondTurn: Bool { speakerSegmentCount > turnSegmentCount }
    private var thisScopeLabel: String { turnSegmentCount == 1 ? "This segment" : "This turn" }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let targetId = pendingTargetId {
                scopeStep(targetId: targetId)
            } else {
                renameSection
                if !otherSpeakers.isEmpty {
                    Divider()
                    moveSection
                }
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    // MARK: Rename

    private var renameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RENAME SPEAKER").font(.caption2.bold()).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                Button("Rename") { commitRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(trimmedName.isEmpty)
            }

            if !nameSuggestions.isEmpty {
                Text("Suggestions").font(.caption2).foregroundStyle(.tertiary)
                FlowLayout(spacing: 4) {
                    ForEach(nameSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { onRename(suggestion) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .onAppear { nameFocused = true }
    }

    private func commitRename() {
        guard !trimmedName.isEmpty else { return }
        onRename(trimmedName)
    }

    // MARK: Move this turn to

    private var moveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MOVE \(thisScopeLabel.uppercased()) TO").font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(otherSpeakers) { target in
                Button { selectMoveTarget(target.id) } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(TranscriptDesignTokens.speakerColor(for: target.id))
                            .frame(width: 8, height: 8)
                        Text(target.displayName).font(.system(size: 12))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func selectMoveTarget(_ id: String) {
        if hasSegmentsBeyondTurn {
            pendingTargetId = id
        } else {
            // The turn is the whole speaker — no scope choice to make.
            onReassign(id, .allOfSpeaker)
        }
    }

    // MARK: Scope step (reassignment only)

    private func scopeStep(targetId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MOVE WHICH SEGMENTS?").font(.caption2.bold()).foregroundStyle(.secondary)
            Button(thisScopeLabel) { onReassign(targetId, .theseSegments) }
                .buttonStyle(.bordered).controlSize(.small)
            Button("All \(speakerSegmentCount) from \u{201C}\(currentDisplayName)\u{201D}") {
                onReassign(targetId, .allOfSpeaker)
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            Button("Back") { pendingTargetId = nil }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
