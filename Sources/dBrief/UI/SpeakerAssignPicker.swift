import SwiftUI

/// Popover body for assigning/renaming a transcript speaker. Step 1 picks a person
/// (existing speaker or a typed new name); step 2 (shown only when the speaker has
/// segments beyond this turn) picks the scope.
struct SpeakerAssignPicker: View {
    let candidates: [SpeakerCandidate]
    let currentDisplayName: String
    let speakerSegmentCount: Int
    let turnSegmentCount: Int
    let onChoose: (SpeakerChoice, ReassignScope) -> Void
    let onCancel: () -> Void

    private enum Step: Equatable { case pick, scope }

    @State private var step: Step = .pick
    @State private var pendingChoice: SpeakerChoice?
    @State private var addingNew = false
    @State private var newName = ""
    @FocusState private var newNameFocused: Bool

    private var hasSegmentsBeyondTurn: Bool { speakerSegmentCount > turnSegmentCount }
    private var thisScopeLabel: String { turnSegmentCount == 1 ? "This segment" : "This turn" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch step {
            case .pick:  pickStep
            case .scope: scopeStep
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    // MARK: Pick step

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Assign speaker")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(candidates) { c in
                Button { choose(candidate: c) } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(TranscriptDesignTokens.speakerColor(for: c.existingSpeakerId))
                            .frame(width: 8, height: 8)
                        Text(c.displayName).font(.system(size: 12))
                        Spacer()
                        if c.isCurrent {
                            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(c.existingSpeakerId == nil && c.isCurrent)
            }

            Divider()

            if addingNew {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($newNameFocused)
                    .onSubmit { confirmNewName() }
                HStack {
                    Button("Cancel") { addingNew = false; newName = "" }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Add") { confirmNewName() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button { addingNew = true; newNameFocused = true } label: {
                    Label("Add someone…", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func choose(candidate: SpeakerCandidate) {
        if candidate.isCurrent { onCancel(); return }   // no-op
        // A name-only candidate (no existing speakerId) routes through .new so it
        // mints or merges by name; an existing speaker reassigns by id.
        let choice: SpeakerChoice
        if let id = candidate.existingSpeakerId { choice = .existing(speakerId: id) }
        else { choice = .new(name: candidate.displayName) }
        advance(with: choice)
    }

    private func confirmNewName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        advance(with: .new(name: name))
    }

    private func advance(with choice: SpeakerChoice) {
        if hasSegmentsBeyondTurn {
            pendingChoice = choice
            step = .scope
        } else {
            onChoose(choice, .allOfSpeaker)
        }
    }

    // MARK: Scope step

    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply to…").font(.caption.bold()).foregroundStyle(.secondary)
            Button(thisScopeLabel) {
                if let c = pendingChoice { onChoose(c, .theseSegments) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            Button("All \(speakerSegmentCount) from \u{201C}\(currentDisplayName)\u{201D}") {
                if let c = pendingChoice { onChoose(c, .allOfSpeaker) }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            Button("Back") { step = .pick }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
