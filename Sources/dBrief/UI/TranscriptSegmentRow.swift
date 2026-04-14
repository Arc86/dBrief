import SwiftUI

enum SegmentDisplayMode {
    case transcript  // Chat-style: speaker left column, clean text right
    case segments    // Card with word-token highlighting
}

struct TranscriptSegmentRow: View {
    let segment: RichSegment
    let speakerLabels: [SpeakerLabel]
    let isActive: Bool
    let currentTime: TimeInterval
    let displayMode: SegmentDisplayMode
    let showSpeakerNames: Bool
    let fontSize: Int
    let onSeek: (Double) -> Void
    let onToggleStar: () -> Void
    let onSave: (String) -> Void
    let onRenameSpeaker: (String, String) -> Void  // (speakerId, newDisplayName)

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var showingSpeakerRename = false
    @State private var speakerRenameText = ""

    var body: some View {
        switch displayMode {
        case .transcript: transcriptRow
        case .segments:   segmentsRow
        }
    }

    // MARK: - Transcript (chat-style)

    private var transcriptRow: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left column: speaker name
            speakerColumn
                .frame(width: 80, alignment: .trailing)

            // Right column: timestamp + content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button(formattedTimestamp(segment.start)) { onSeek(segment.start) }
                        .buttonStyle(.plain)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)

                    if isHovered || segment.isStarred {
                        Button { onToggleStar() } label: {
                            Image(systemName: segment.isStarred ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(segment.isStarred ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)

                        Button { startEditing() } label: {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                segmentBody
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.06) :
                    isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var speakerColumn: some View {
        if showSpeakerNames, let speakerId = segment.speakerId {
            let displayName = speakerDisplayName(for: speakerId)
            let color = speakerColor(for: speakerId)
            Button {
                speakerRenameText = displayName
                showingSpeakerRename = true
            } label: {
                Text(displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingSpeakerRename, arrowEdge: .trailing) {
                speakerRenamePopover(speakerId: speakerId, displayName: displayName)
            }
        } else {
            Color.clear
        }
    }

    // MARK: - Segments (card-style)

    private var segmentsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                if let speakerId = segment.speakerId, showSpeakerNames {
                    let displayName = speakerDisplayName(for: speakerId)
                    let color = speakerColor(for: speakerId)
                    Text(displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .foregroundStyle(color)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onTapGesture {
                            speakerRenameText = displayName
                            showingSpeakerRename = true
                        }
                        .popover(isPresented: $showingSpeakerRename, arrowEdge: .bottom) {
                            speakerRenamePopover(speakerId: speakerId, displayName: displayName)
                        }
                }

                Button(formattedTimestamp(segment.start)) { onSeek(segment.start) }
                    .buttonStyle(.plain)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if isHovered || segment.isStarred || isEditing {
                    HStack(spacing: 4) {
                        Button { onToggleStar() } label: {
                            Image(systemName: segment.isStarred ? "star.fill" : "star")
                                .foregroundStyle(segment.isStarred ? .yellow : .secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)

                        Button { startEditing() } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            segmentBody
        }
        .padding(10)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(cardBorder, lineWidth: 1))
        .onHover { isHovered = $0 }
    }

    private var cardBackground: Color {
        if isActive { return Color.accentColor.opacity(0.08) }
        if segment.isStarred { return Color.yellow.opacity(0.06) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorder: Color {
        if isEditing { return .accentColor }
        if isActive { return Color.accentColor.opacity(0.5) }
        if segment.isStarred { return Color.yellow.opacity(0.5) }
        if isHovered { return Color(nsColor: .separatorColor) }
        return .clear
    }

    // MARK: - Shared body content

    @ViewBuilder
    private var segmentBody: some View {
        if isEditing {
            TextEditor(text: $editText)
                .font(.system(size: CGFloat(fontSize)))
                .frame(minHeight: 48)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
                .onChange(of: editText) { _, newText in scheduleSave(newText) }
                .onKeyPress(.escape) { cancelEditing(); return .handled }

            Text("Esc to cancel · Changes auto-saved")
                .font(.caption2)
                .foregroundStyle(.tertiary)

        } else if displayMode == .segments && !segment.tokens.isEmpty {
            FlowLayout(spacing: 2) {
                ForEach(segment.tokens.indices, id: \.self) { i in
                    let token = segment.tokens[i]
                    let isPlaying: Bool = {
                        guard let s = token.start, let e = token.end else { return false }
                        return currentTime >= s && currentTime < e
                    }()
                    Text(token.text)
                        .font(.system(size: CGFloat(fontSize)))
                        .padding(.horizontal, 1)
                        .background(isPlaying ? Color.accentColor.opacity(0.4) : Color.clear)
                        .foregroundStyle(isPlaying ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .onTapGesture { onSeek(token.start ?? segment.start) }
                }
            }
        } else {
            Text(segment.text)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onSeek(segment.start) }
        }
    }

    // MARK: - Speaker rename popover

    @ViewBuilder
    private func speakerRenamePopover(speakerId: String, displayName: String) -> some View {
        VStack(spacing: 8) {
            Text("Rename Speaker")
                .font(.caption.bold())
            TextField("Name", text: $speakerRenameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onSubmit { commitRename(speakerId: speakerId) }
            HStack {
                Button("Cancel") { showingSpeakerRename = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Save") { commitRename(speakerId: speakerId) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func speakerDisplayName(for speakerId: String) -> String {
        speakerLabels.first(where: { $0.id == speakerId })?.displayName ?? speakerId
    }

    private func speakerColor(for speakerId: String) -> Color {
        let palette: [Color] = [.accentColor, .orange, .green, .purple, .pink, .cyan, .yellow, .indigo]
        let hash = abs(speakerId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return palette[hash % palette.count]
    }

    private func formattedTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func startEditing() {
        editText = segment.text
        isEditing = true
    }

    private func cancelEditing() {
        saveTask?.cancel()
        saveTask = nil
        isEditing = false
    }

    private func scheduleSave(_ text: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, isEditing else { return }
            onSave(text)
        }
    }

    private func commitRename(speakerId: String) {
        let name = speakerRenameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { onRenameSpeaker(speakerId, name) }
        showingSpeakerRename = false
    }
}
