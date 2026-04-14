import SwiftUI

struct TranscriptSidePanel: View {
    @Binding var richTranscript: RichTranscript
    let recording: Recording
    @Binding var fontSize: Int
    @Binding var showSpeakerNames: Bool

    @State private var metadataExpanded = false
    @State private var renamingId: String? = nil
    @State private var renameText = ""

    private var uniqueSpeakerIds: [String] {
        var seen = Set<String>()
        return richTranscript.segments.compactMap { seg -> String? in
            guard let id = seg.speakerId, !seen.contains(id) else { return nil }
            seen.insert(id)
            return id
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: People
                if !uniqueSpeakerIds.isEmpty {
                    sectionHeader("People")

                    VStack(spacing: 0) {
                        ForEach(uniqueSpeakerIds, id: \.self) { speakerId in
                            speakerRow(for: speakerId)
                            Divider().padding(.leading, 28)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                    Divider()
                }

                // MARK: Display
                sectionHeader("Display")

                VStack(spacing: 10) {
                    HStack {
                        Text("Font Size")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Stepper(value: $fontSize, in: 12...24) {
                            Text("\(fontSize) pt")
                                .font(.caption.monospacedDigit())
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    Toggle(isOn: $showSpeakerNames) {
                        Text("Speaker Names")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

                Divider()

                // MARK: Metadata
                DisclosureGroup(
                    isExpanded: $metadataExpanded
                ) {
                    metadataContent
                        .padding(.top, 6)
                } label: {
                    Text("Metadata")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Speaker row

    @ViewBuilder
    private func speakerRow(for speakerId: String) -> some View {
        let displayName = speakerDisplayName(for: speakerId)
        let color = speakerColor(for: speakerId)
        let isRenaming = renamingId == speakerId

        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            if isRenaming {
                TextField("Name", text: $renameText, onCommit: { commitRename(speakerId: speakerId) })
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onKeyPress(.escape) {
                        renamingId = nil
                        return .handled
                    }
                    .onAppear { renameText = displayName }
            } else {
                Text(displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .onTapGesture {
                        renameText = displayName
                        renamingId = speakerId
                    }
            }

            Spacer()

            if isRenaming {
                Button("Save") { commitRename(speakerId: speakerId) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                Button {
                    renameText = displayName
                    renamingId = speakerId
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Metadata

    private var metadataContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            metaRow("Duration", value: recording.formattedDuration)
            metaRow("Recorded", value: recording.date.formatted(date: .abbreviated, time: .shortened))

            if let language = recording.transcription?.language {
                metaRow("Language", value: language.uppercased())
            }

            if let speakerCount = recording.transcription?.speakerCount, speakerCount > 0 {
                metaRow("Speakers", value: "\(speakerCount)")
            }

            let segCount = richTranscript.segments.count
            metaRow("Segments", value: "\(segCount)")

            let wordCount = richTranscript.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
            metaRow("Words", value: wordCount.formatted())

            if let url = recording.finalizedAudioURL,
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? Int64 {
                metaRow("File Size", value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func metaRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    // MARK: - Helpers

    private func speakerDisplayName(for speakerId: String) -> String {
        richTranscript.speakerLabels.first(where: { $0.id == speakerId })?.displayName ?? speakerId
    }

    private func speakerColor(for speakerId: String) -> Color {
        let palette: [Color] = [.accentColor, .orange, .green, .purple, .pink, .cyan, .yellow, .indigo]
        let hash = abs(speakerId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return palette[hash % palette.count]
    }

    private func commitRename(speakerId: String) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { renamingId = nil; return }

        if let idx = richTranscript.speakerLabels.firstIndex(where: { $0.id == speakerId }) {
            richTranscript.speakerLabels[idx].displayName = name
        } else {
            richTranscript.speakerLabels.append(SpeakerLabel(id: speakerId, displayName: name))
        }
        renamingId = nil
    }
}
