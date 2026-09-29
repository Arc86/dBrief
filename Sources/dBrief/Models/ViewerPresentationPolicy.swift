enum ViewerDocumentMode: String, CaseIterable, Hashable, Sendable {
    case summary
    case transcript
    case actions
    case meetingInsights

    var displayName: String {
        switch self {
        case .summary: "Summary"
        case .transcript: "Transcript"
        case .actions: "Actions"
        case .meetingInsights: "Meeting Insights"
        }
    }
}

enum ViewerPresentationPolicy {
    static func initialMode(hasSummary: Bool) -> ViewerDocumentMode {
        hasSummary ? .summary : .transcript
    }

    /// The data-driven default applies once per opened recording; later reloads
    /// (reprocess, speaker review) keep whichever tab the user is on.
    static func modeAfterLoad(
        current: ViewerDocumentMode,
        hasAppliedInitialMode: Bool,
        hasSummary: Bool
    ) -> ViewerDocumentMode {
        hasAppliedInitialMode ? current : initialMode(hasSummary: hasSummary)
    }

    static func showsPlayback(
        mode: ViewerDocumentMode,
        hasFinalizedAudio: Bool,
        isLive: Bool
    ) -> Bool {
        mode == .transcript && hasFinalizedAudio && !isLive
    }
}
