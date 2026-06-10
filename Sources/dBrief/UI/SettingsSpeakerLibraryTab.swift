import SwiftUI

/// Manage the on-device speaker-recognition library: enable recognition, tune
/// the match threshold, and view/rename/delete enrolled people. People are
/// enrolled from the transcript window ("Remember this person"); this screen is
/// where they're reviewed and purged. Power-User-gated, like Profiles.
struct SettingsSpeakerLibraryTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(SpeakerRecognitionService.self) private var speakerRecognition

    @State private var renamingId: UUID?
    @State private var renameText = ""
    @State private var showForgetAllConfirm = false

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Speaker Recognition") {
                Toggle("Recognize known speakers", isOn: $settings.speakerRecognitionEnabled)
                Text("When diarization runs, match each voice against your library and apply known people's names automatically. Requires Speaker diarization (Settings → AI & Models → Transcription).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.speakerRecognitionEnabled {
                    LabeledContent("Match strictness") {
                        HStack(spacing: 8) {
                            Slider(value: $settings.speakerMatchThreshold, in: 0.4...0.9)
                                .frame(width: 180)
                            Text(String(format: "%.2f", settings.speakerMatchThreshold))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Higher is stricter — fewer false matches, but a known voice may go unrecognized. Lower recognizes more readily. Default 0.70.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            Section("Known People") {
                if speakerRecognition.library.speakers.isEmpty {
                    Text("No one yet. Open a transcript with diarized speakers, name a speaker, and choose “Remember this person” to add them here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(speakerRecognition.library.speakers) { person in
                        speakerRow(person)
                    }
                }
            }
            .listRowBackground(Color.clear)

            Section("Privacy") {
                Text("Voiceprints are biometric data. They are stored only on this Mac (Application Support), never uploaded, and never written into transcripts, notes, or webhook payloads — only the resolved names appear there. Embeddings are one-way vectors, not recoverable audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    showForgetAllConfirm = true
                } label: {
                    Label("Forget all speakers", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(speakerRecognition.library.speakers.isEmpty)
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog("Forget all saved speakers?",
                            isPresented: $showForgetAllConfirm, titleVisibility: .visible) {
            Button("Forget Everyone", role: .destructive) {
                Task { await speakerRecognition.forgetAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every enrolled voiceprint from this Mac. Future recordings won't auto-name anyone until you enroll them again.")
        }
        .alert("Rename Speaker", isPresented: Binding(
            get: { renamingId != nil },
            set: { if !$0 { renamingId = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renamingId { Task { await speakerRecognition.rename(id: id, to: renameText) } }
                renamingId = nil
            }
            Button("Cancel", role: .cancel) { renamingId = nil }
        }
        .task { await speakerRecognition.reload() }
    }

    private func speakerRow(_ person: KnownSpeaker) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.25))
                Text(initials(person.name))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.medium))
                Text(subtitle(person)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                renameText = person.name
                renamingId = person.id
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Rename")
            Button(role: .destructive) {
                Task { await speakerRecognition.delete(id: person.id) }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ person: KnownSpeaker) -> String {
        let samples = person.sampleCount == 1 ? "1 voice sample" : "\(person.sampleCount) voice samples"
        guard let last = person.lastSeenAt else { return samples }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "\(samples) · seen \(f.localizedString(for: last, relativeTo: Date()))"
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }
}
