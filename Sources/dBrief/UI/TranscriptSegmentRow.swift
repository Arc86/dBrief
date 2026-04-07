import SwiftUI

struct TranscriptSegmentRow: View {
    let segment: RichTranscript.Segment
    let isActive: Bool
    let onSeek: (Double) -> Void
    let onStarToggle: () -> Void
    let onEdit: (String) -> Void

    @State private var isEditing = false
    @State private var editedText: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onStarToggle) {
                Image(systemName: segment.isStarred ? "star.fill" : "star")
                    .foregroundStyle(segment.isStarred ? .yellow : .secondary)
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(formattedTimestamp(segment.start))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                if isEditing {
                    TextField("Edit text", text: $editedText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .onSubmit {
                            onEdit(editedText)
                            isEditing = false
                        }
                        .onAppear { editedText = segment.displayText }
                } else {
                    Text(segment.displayText)
                        .font(.callout)
                        .foregroundStyle(isActive ? .primary : .primary)
                        .background(isActive ? Color.blue.opacity(0.1) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onTapGesture {
                            onSeek(segment.start)
                        }
                        .onLongPressGesture {
                            editedText = segment.displayText
                            isEditing = true
                        }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }

    private func formattedTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
