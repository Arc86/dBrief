import Foundation

struct ProfileMatchRule: Codable, Hashable, Identifiable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case title, callApplication, calendarTitle, calendarNotes, calendarLocation, attendeeDomain

        var title: String {
            switch self {
            case .title: "Recording title"
            case .callApplication: "Call application"
            case .calendarTitle: "Calendar title"
            case .calendarNotes: "Calendar notes"
            case .calendarLocation: "Calendar location"
            case .attendeeDomain: "Attendee email domain"
            }
        }
    }
    var id = UUID()
    var field: Field
    var value: String
}

struct ProfileMatchContext: Sendable {
    var title: String
    var callApplication = ""
    var calendarTitle = ""
    var calendarNotes = ""
    var calendarLocation = ""
    var attendeeEmails: [String] = []

    @MainActor init(recording: Recording) {
        title = recording.meetingTitleDraft
        callApplication = recording.associatedApp ?? ""
        calendarTitle = recording.calendarEvent?.title ?? ""
        calendarNotes = recording.calendarEvent?.body ?? ""
        calendarLocation = recording.calendarEvent?.location ?? ""
        attendeeEmails = recording.calendarEvent?.attendees.compactMap(\.email) ?? []
    }

    init(title: String, callApplication: String = "", calendarTitle: String = "", calendarNotes: String = "",
         calendarLocation: String = "", attendeeEmails: [String] = []) {
        self.title = title
        self.callApplication = callApplication
        self.calendarTitle = calendarTitle
        self.calendarNotes = calendarNotes
        self.calendarLocation = calendarLocation
        self.attendeeEmails = attendeeEmails
    }
}

enum ProfileMatcher {
    struct Match: Equatable, Sendable {
        let profileID: UUID
        let reasons: [String]
    }

    /// All conditions in a profile must match. Higher priority wins, then more
    /// conditions, then the stable UUID. Array/UI order never changes a tie.
    static func match(profiles: [MeetingProfile], context: ProfileMatchContext) -> Match? {
        for profile in profiles.sorted(by: {
            if $0.matchPriority != $1.matchPriority { return $0.matchPriority > $1.matchPriority }
            if $0.matchingRules.count != $1.matchingRules.count { return $0.matchingRules.count > $1.matchingRules.count }
            return $0.id.uuidString < $1.id.uuidString
        }) where profile.automaticMatchingEnabled && !profile.matchingRules.isEmpty {
            guard profile.matchingRules.allSatisfy({ matches($0, context: context) }) else { continue }
            return Match(profileID: profile.id, reasons: profile.matchingRules.map {
                "\($0.field.title) \($0.field == .attendeeDomain ? "is" : "contains") “\($0.value.trimmingCharacters(in: .whitespacesAndNewlines))”"
            })
        }
        return nil
    }

    private static func matches(_ rule: ProfileMatchRule, context: ProfileMatchContext) -> Bool {
        let value = rule.field == .attendeeDomain
            ? rule.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : normalized(rule.value)
        guard !value.isEmpty else { return false }
        if rule.field == .attendeeDomain {
            let labels = value.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.last != "-"
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return false }
            return context.attendeeEmails.contains { email in
                let parts = email.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", omittingEmptySubsequences: false)
                return parts.count == 2 && !parts[0].isEmpty && parts[1].lowercased() == value
            }
        }
        let source: String
        switch rule.field {
        case .title: source = context.title
        case .callApplication: source = context.callApplication
        case .calendarTitle: source = context.calendarTitle
        case .calendarNotes: source = context.calendarNotes
        case .calendarLocation: source = context.calendarLocation
        case .attendeeDomain: return false
        }
        return normalized(source).contains(value)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Session state for one recording, independent of late calendar lookups.
struct RecordingProfileSelection {
    private(set) var baselineID: UUID?
    private(set) var match: ProfileMatcher.Match?
    private(set) var appliedID: UUID?
    private(set) var isManual = false
    private(set) var isDeferred = false
    private var manualBaselineID: UUID?

    init(baselineID: UUID? = nil) {
        self.baselineID = baselineID
    }

    /// The review belongs to this recording, even while another job temporarily
    /// owns the app's resolved settings. Never display that worker's profile.
    func reviewProfileID(savedManualID: UUID) -> UUID {
        let observedManualID = isManual ? manualBaselineID : baselineID
        if let observedManualID, observedManualID != savedManualID { return savedManualID }
        return appliedID ?? baselineID ?? savedManualID
    }

    mutating func chooseManually(_ id: UUID, savedManualID: UUID? = nil) {
        isManual = true
        isDeferred = false
        appliedID = id
        manualBaselineID = savedManualID
    }

    /// Keep the recording's explicit choice when a previous worker releases its
    /// temporary profile. A later choice in Settings still takes precedence.
    mutating func retainedManualChoice(savedManualID: UUID) -> UUID? {
        guard isManual else { return nil }
        if let manualBaselineID, manualBaselineID != savedManualID {
            appliedID = savedManualID
        }
        manualBaselineID = savedManualID
        return appliedID
    }

    mutating func evaluate(profiles: [MeetingProfile], context: ProfileMatchContext, activeID: UUID,
                           workerBusy: Bool, manualID: UUID? = nil) -> UUID? {
        guard !isManual else { return nil }
        if baselineID == nil { baselineID = manualID ?? activeID }
        // A profile changed outside this selector is also a manual override.
        if let manualID, manualID != baselineID { chooseManually(manualID, savedManualID: manualID); return nil }
        if manualID == nil, let previousID = appliedID ?? baselineID, previousID != activeID {
            chooseManually(activeID)
            return nil
        }
        match = ProfileMatcher.match(profiles: profiles, context: context)
        let target = match?.profileID ?? baselineID ?? activeID
        guard profiles.contains(where: { $0.id == target }) else { return nil }
        isDeferred = workerBusy && target != activeID
        if workerBusy && target == activeID {
            // No settings change is needed, but the recording still owns this
            // choice for its review, countdown and possible overflow queue.
            appliedID = target
        }
        guard !workerBusy else { return nil }
        appliedID = target
        return target
    }
}
