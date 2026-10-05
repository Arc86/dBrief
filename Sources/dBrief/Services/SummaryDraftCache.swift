import Foundation

/// The inline summary edit in progress for one recording.
struct SummaryEditState: Equatable, Sendable {
    /// The analysis as it was when editing began; saving merges against it.
    let insightsBaseline: RecordingInsights
    var draft: MarkdownEditorDraft

    init(insights: RecordingInsights) {
        insightsBaseline = insights
        draft = MarkdownEditorDraft(initial: insights.summary)
    }

    /// True when the stored summary changed since editing began (e.g. reprocessing
    /// regenerated it) — saving the draft would silently overwrite newer analysis.
    /// A stored summary that already equals the draft is not stale: an earlier save
    /// wrote the sidecar but failed later (e.g. the linked Markdown note), so the
    /// retry must go through.
    func isStale(currentSummary: String?) -> Bool {
        guard currentSummary != insightsBaseline.summary else { return false }
        guard let currentSummary else { return true }
        return Self.trimmed(currentSummary) != Self.trimmed(draft.current)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Unsaved summary drafts for this app run, keyed by recording file URL, so
/// switching recordings (which rebuilds the viewer) never loses typed text.
@MainActor
final class SummaryDraftCache {
    static let shared = SummaryDraftCache()

    private var drafts: [URL: SummaryEditState] = [:]

    init() {}

    /// Keeps only dirty drafts; `nil` or a clean draft clears the entry.
    func store(_ state: SummaryEditState?, for url: URL) {
        if let state, state.draft.isDirty {
            drafts[url] = state
        } else {
            drafts[url] = nil
        }
    }

    func restore(for url: URL) -> SummaryEditState? {
        drafts[url]
    }
}
