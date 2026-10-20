import Foundation

/// A frozen, read-only snapshot of one recording for the Focus Reader: the
/// notes (summary, owner-grouped action items, tags) and the transcript turns.
struct FocusReaderContent {
    enum Page: String, CaseIterable, Sendable {
        case notes, transcript

        var title: String {
            switch self {
            case .notes: String(localized: "Notes")
            case .transcript: String(localized: "Transcript")
            }
        }
    }

    let recordingID: UUID
    let title: String
    let subtitle: String
    let summary: String?
    let actionGroups: [ActionItemGroup]
    let completedActions: Set<String>
    let tags: [String]
    let turns: [TranscriptTurnRowModel]

    var hasNotes: Bool { summary != nil || !actionGroups.isEmpty || !tags.isEmpty }

    /// Notes first when there is analysis; nothing when there's nothing to read.
    var pages: [Page] { (hasNotes ? [.notes] : []) + (turns.isEmpty ? [] : [.transcript]) }
    var initialPage: Page? { pages.first }

    static func make(recordingID: UUID, title: String, date: Date, duration: TimeInterval,
                     insights: RecordingInsights?, owners: [String], turns: [TranscriptTurnRowModel],
                     locale: Locale = .current, timeZone: TimeZone = .current) -> FocusReaderContent {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let summary = insights?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Raw strings stay the identity for completion state; placeholders go.
        let actions = (insights?.actionItems ?? []).filter { ActionItemText.cleaned($0) != nil }
        return FocusReaderContent(
            recordingID: recordingID, title: title,
            subtitle: "\(formatter.string(from: date)) · \(durationText(duration))",
            summary: summary?.isEmpty == false ? summary : nil,
            actionGroups: ActionItemParser.group(actions, knownOwners: owners),
            completedActions: insights?.completedActions ?? [],
            tags: (insights?.tags ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            turns: turns)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        return minutes >= 60 ? String(localized: "\(minutes / 60) h \(minutes % 60) min") : String(localized: "\(minutes) min")
    }
}

/// Hands the snapshot from the viewer to the Focus Reader window.
@MainActor
@Observable
final class FocusReaderStore {
    var content: FocusReaderContent?
    var page: FocusReaderContent.Page = .notes

    func present(_ content: FocusReaderContent) {
        self.content = content
        page = content.initialPage ?? .notes
    }
}
