import SwiftUI

/// Meeting-specific information already present on the recording and its analysis.
/// Speaker correction controls are supplied by the viewer so they keep using its
/// existing rename, reassignment, and “This is me” actions.
struct MeetingInsightsView<SpeakerContent: View>: View {
    let recording: Recording
    let richTranscript: RichTranscript?
    let insights: RecordingInsights?
    let isReadOnly: Bool
    let onPrivacyReceipt: () -> Void
    private let speakerContent: () -> SpeakerContent

    @Environment(\.viewerPalette) private var palette

    init(
        recording: Recording,
        richTranscript: RichTranscript?,
        insights: RecordingInsights?,
        isReadOnly: Bool,
        onPrivacyReceipt: @escaping () -> Void,
        @ViewBuilder speakerContent: @escaping () -> SpeakerContent
    ) {
        self.recording = recording
        self.richTranscript = richTranscript
        self.insights = insights
        self.isReadOnly = isReadOnly
        self.onPrivacyReceipt = onPrivacyReceipt
        self.speakerContent = speakerContent
    }

    private var content: MeetingInsightsPresentation {
        MeetingInsightsPresentation(recording: recording, richTranscript: richTranscript, insights: insights)
    }

    var body: some View {
        let content = content
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MeetingInformationCard(content: content)
                if !content.participants.isEmpty {
                    MeetingParticipantsCard(names: content.participants)
                }
                MeetingSpeakersCard(
                    speakers: content.speakers,
                    transcriptAvailable: richTranscript != nil,
                    isReadOnly: isReadOnly,
                    speakerContent: speakerContent
                )
                MeetingProcessingCard(
                    tags: content.tags,
                    sentiment: content.sentiment,
                    origins: content.origins,
                    warnings: content.warnings
                )
                MeetingPrivacyCard(onPrivacyReceipt: onPrivacyReceipt)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.visible)
    }
}

/// Shared source mapping for the visible Insights content and its Copy command.
@MainActor
struct MeetingInsightsPresentation {
    struct Speaker: Identifiable, Equatable {
        let id: String
        let name: String
        let isMe: Bool
    }

    struct Origin: Identifiable, Equatable {
        let id: String
        let label: String
        let modelName: String?
    }

    let title: String?
    let date: Date
    let duration: String
    let audioFileName: String?
    let fileSize: String?
    let participants: [String]
    let speakers: [Speaker]
    let tags: [String]
    let sentiment: String?
    let origins: [Origin]
    let warnings: [String]

    init(recording: Recording, richTranscript: RichTranscript?, insights: RecordingInsights?) {
        let rawTitle = (recording.generatedTitle ?? recording.meetingTitleDraft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = rawTitle.isEmpty ? nil : rawTitle
        date = recording.date
        duration = recording.duration.isFinite && recording.duration > 0 ? recording.formattedDuration : "Unavailable"

        let audioURL = recording.finalizedAudioURL ?? recording.fileURL
        let rawFileName = audioURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        audioFileName = rawFileName.isEmpty ? nil : rawFileName
        fileSize = recording.fileSize > 0 ? recording.formattedFileSize : nil

        participants = PersonName.displayList(
            recording.participants + (recording.calendarEvent?.attendeeNames ?? [])
        )

        let transcript = richTranscript ?? recording.richTranscript
        var seenSpeakerIDs = Set<String>()
        let speakerIDs = (transcript?.segments ?? []).compactMap(\.speakerId).filter { id in
            !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seenSpeakerIDs.insert(id).inserted
        }
        speakers = speakerIDs.map { id in
            let storedName = transcript?.speakerLabels.first(where: { $0.id == id })?.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = storedName.flatMap { $0.isEmpty ? nil : $0 } ?? id
            return Speaker(id: id, name: name, isMe: id == transcript?.meSpeakerId)
        }

        let storedTags = insights?.tags ?? recording.tags ?? []
        tags = storedTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let rawSentiment = insights?.sentiment ?? recording.sentiment
        let trimmedSentiment = rawSentiment?.trimmingCharacters(in: .whitespacesAndNewlines)
        sentiment = trimmedSentiment.flatMap { $0.isEmpty ? nil : $0 }

        let provenance = insights?.modelProvenance
        let recordingProvenance = recording.analysisModelProvenance
        let hasSummary = !(insights?.summary ?? recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasActions = !(insights?.actionItems ?? recording.actionItems ?? [])
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let hasTagsOrSentiment = !tags.isEmpty || sentiment != nil

        var origins: [Origin] = []
        if hasSummary {
            origins.append(Origin(
                id: "summary", label: "Summary",
                modelName: Self.nonempty(provenance?.summary ?? recordingProvenance?.summary)
            ))
        }
        if hasActions {
            origins.append(Origin(
                id: "actions", label: "Actions",
                modelName: Self.nonempty(provenance?.actionItems ?? recordingProvenance?.actionItems)
            ))
        }
        if hasTagsOrSentiment {
            origins.append(Origin(
                id: "tags", label: "Tags and sentiment",
                modelName: Self.nonempty(provenance?.tags ?? recordingProvenance?.tags)
            ))
        }
        self.origins = origins
        warnings = recording.finalizationWarnings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func plainText() -> String {
        var sections: [String] = []

        var recordingDetails: [String] = []
        if let title { recordingDetails.append("Title: \(title)") }
        recordingDetails.append("Date: \(date.formatted(date: .complete, time: .shortened))")
        recordingDetails.append("Duration: \(duration)")
        if let audioFileName { recordingDetails.append("Audio file: \(audioFileName)") }
        if let fileSize { recordingDetails.append("File size: \(fileSize)") }
        sections.append(recordingDetails.joined(separator: "\n"))

        if !participants.isEmpty {
            sections.append("Participants\n\n\(participants.map { "- \($0)" }.joined(separator: "\n"))")
        }
        if !speakers.isEmpty {
            let rows = speakers.map { speaker in
                "- \(speaker.name)\(speaker.isMe ? " (This is me)" : "")"
            }
            sections.append("Speakers\n\n\(rows.joined(separator: "\n"))")
        }
        if !tags.isEmpty { sections.append("Tags: \(tags.joined(separator: ", "))") }
        if let sentiment { sections.append("Sentiment: \(sentiment)") }
        if !origins.isEmpty {
            let rows = origins.map { "- \($0.label): \($0.modelName ?? "Origin not recorded")" }
            sections.append("Processing origin\n\n\(rows.joined(separator: "\n"))")
        }
        if !warnings.isEmpty {
            sections.append("Processing warnings\n\n\(warnings.map { "- \($0)" }.joined(separator: "\n"))")
        }
        return sections.joined(separator: "\n\n")
    }
}

/// Shared copy formatter for the Meeting Insights tab.
@MainActor
enum MeetingInsightsCopy {
    static func text(
        recording: Recording,
        richTranscript: RichTranscript?,
        insights: RecordingInsights?
    ) -> String {
        MeetingInsightsPresentation(
            recording: recording,
            richTranscript: richTranscript,
            insights: insights
        ).plainText()
    }
}

private struct MeetingInformationCard: View {
    let content: MeetingInsightsPresentation
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MeetingCardHeading(title: "Recording", symbol: "record.circle")
            MeetingFactRow(label: "Date", value: content.date.formatted(date: .complete, time: .shortened))
            MeetingFactRow(label: "Duration", value: content.duration)
            if let audioFileName = content.audioFileName {
                MeetingFactRow(label: "Audio file", value: audioFileName, selectable: true)
            }
            if let fileSize = content.fileSize {
                MeetingFactRow(label: "File size", value: fileSize)
            }
        }
        .padding(18)
        .modifier(ViewerCard())
        .accessibilityElement(children: .contain)
    }
}

private struct MeetingParticipantsCard: View {
    let names: [String]
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingCardHeading(title: "Participants", symbol: "person.2")
            Text(names.joined(separator: ", "))
                .font(ViewerFonts.font(for: reading, effectiveMode: mode))
                .lineSpacing(ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode))
                .foregroundStyle(palette.text.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .modifier(ViewerCard())
    }
}

private struct MeetingSpeakersCard<SpeakerContent: View>: View {
    let speakers: [MeetingInsightsPresentation.Speaker]
    let transcriptAvailable: Bool
    let isReadOnly: Bool
    @ViewBuilder let speakerContent: () -> SpeakerContent
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingCardHeading(title: "Speakers", symbol: "person.wave.2")
            if speakers.isEmpty {
                Text(transcriptAvailable
                     ? "No speakers were identified in the transcript."
                     : "Speaker details are unavailable because no transcript is attached.")
                    .font(ViewerFonts.font(for: reading, effectiveMode: mode))
                    .lineSpacing(ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode))
                    .foregroundStyle(palette.secondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                speakerContent()
                    .disabled(isReadOnly)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .modifier(ViewerCard())
    }
}

private struct MeetingProcessingCard: View {
    let tags: [String]
    let sentiment: String?
    let origins: [MeetingInsightsPresentation.Origin]
    let warnings: [String]
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MeetingCardHeading(title: "Analysis and processing", symbol: "sparkles")
            if !tags.isEmpty {
                MeetingFactRow(label: "Tags", value: tags.map { "#\($0)" }.joined(separator: "  "), selectable: true)
            }
            if let sentiment {
                MeetingFactRow(label: "Sentiment", value: sentiment, selectable: true)
            }
            if !origins.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Processing origin")
                        .uiFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                    ForEach(origins) { origin in
                        MeetingFactRow(label: origin.label, value: origin.modelName ?? "Origin not recorded")
                    }
                }
            }
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Processing warnings")
                        .uiFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(ViewerFonts.font(for: reading, effectiveMode: mode))
                            .lineSpacing(ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode))
                            .foregroundStyle(palette.text.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if tags.isEmpty && sentiment == nil && origins.isEmpty && warnings.isEmpty {
                Text("No analysis or processing details are available.")
                    .font(ViewerFonts.font(for: reading, effectiveMode: mode))
                    .lineSpacing(ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode))
                    .foregroundStyle(palette.secondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .modifier(ViewerCard())
    }
}

private struct MeetingPrivacyCard: View {
    let onPrivacyReceipt: () -> Void
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingCardHeading(title: "Privacy", symbol: "hand.raised")
            Button(action: onPrivacyReceipt) {
                Label("View privacy receipt", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accentText.color)
            .accessibilityHint("Shows the processing activity recorded for this meeting.")
        }
        .padding(18)
        .modifier(ViewerCard())
    }
}

private struct MeetingCardHeading: View {
    let title: String
    let symbol: String
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        Label(title, systemImage: symbol)
            .uiFont(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.heading.color)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct MeetingFactRow: View {
    let label: String
    let value: String
    var selectable = false
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .uiFont(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondary.color)
            Text(value)
                .font(ViewerFonts.font(for: reading, effectiveMode: mode))
                .lineSpacing(ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode))
                .foregroundStyle(palette.text.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
