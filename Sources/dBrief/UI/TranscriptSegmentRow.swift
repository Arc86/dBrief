import SwiftUI

struct TranscriptSegmentRow: View {
    let segment: RichSegment
    let isActive: Bool
    let currentTime: TimeInterval
    let onSeek: (Double) -> Void
    let onToggleStar: () -> Void
    let onSave: (String) -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var saveTask: Task<Void, Never>?

    private var borderColor: Color {
        if isEditing { return .accentColor }
        if isActive { return Color.accentColor.opacity(0.5) }
        if segment.isStarred { return Color.yellow.opacity(0.5) }
        if isHovered { return Color(nsColor: .separatorColor) }
        return .clear
    }

    private var backgroundColor: Color {
        if isActive { return Color.accentColor.opacity(0.08) }
        if segment.isStarred { return Color.yellow.opacity(0.06) }
        return Color(nsColor: .controlBackgroundColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                // Speaker badge (placeholder until Sub-project 2)
                Text("Speaker 1")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Timestamp button — seeks on tap
                Button(formattedTimestamp(segment.start)) {
                    onSeek(segment.start)
                }
                .buttonStyle(.plain)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

                Spacer()

                // Star and edit controls — revealed on hover (or when starred/editing)
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

            // Body
            if isEditing {
                TextEditor(text: $editText)
                    .font(.callout)
                    .frame(minHeight: 48)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
                    .onChange(of: editText) { _, newText in
                        scheduleSave(newText)
                    }
                    .onKeyPress(.escape) {
                        cancelEditing()
                        return .handled
                    }

                Text("Esc to cancel · Changes auto-saved")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if segment.tokens.isEmpty {
                // No word timestamps — plain text, tap seeks to segment start
                Text(segment.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onSeek(segment.start) }
            } else {
                // Token flow with per-word seeking and current-word highlight
                FlowLayout(spacing: 2) {
                    ForEach(segment.tokens.indices, id: \.self) { i in
                        let token = segment.tokens[i]
                        let isPlaying: Bool = {
                            guard let s = token.start, let e = token.end else { return false }
                            return currentTime >= s && currentTime < e
                        }()
                        Text(token.text)
                            .font(.callout)
                            .padding(.horizontal, 1)
                            .background(isPlaying ? Color.accentColor.opacity(0.4) : Color.clear)
                            .foregroundStyle(isPlaying ? Color.white : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .onTapGesture { onSeek(token.start ?? segment.start) }
                    }
                }
            }
        }
        .padding(10)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
        .onHover { isHovered = $0 }
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

    private func formattedTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
