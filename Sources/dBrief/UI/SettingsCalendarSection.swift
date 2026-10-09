import AppKit
import Combine
import EventKit
import SwiftUI

/// Search targets on the Meetings page render even when the calendar source
/// wouldn't normally show them, so every search result lands on its section.
enum SettingsCalendarVisibility {
    static func showsMatching(source: CalendarSource, request: SettingsSearchRequest?) -> Bool {
        source != .disabled || request?.section == .meetingMatching
    }

    static func showsClaudeCLI(source: CalendarSource, request: SettingsSearchRequest?) -> Bool {
        source == .claudeCLI || request?.section == .calendarCLIAdvanced
    }
}

struct SettingsCalendarSection: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(MicrosoftAuthService.self) private var microsoftAuthService
    @Environment(\.settingsSearchRequest) private var searchRequest

    @State private var outlookSignInError: String?
    @State private var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var availableICalCalendars: [ICalCalendarOption] = []

    var body: some View {
        @Bindable var settings = appSettings
        SettingsCard("Calendar", description: "Pre-fills title, attendees and agenda", section: .calendar) {
            // Display the coerced value so the selection always matches a rendered
            // option (a stale `.outlook` shows as Off while Outlook is hidden); writes
            // persist the raw choice and self-restore once a client ID is configured.
            SettingsRow("Source") {
                Picker("Source", selection: Binding(
                    get: { settings.effectiveCalendarSource },
                    set: { settings.calendarSource = $0 }
                )) {
                    Text("Off").tag(CalendarSource.disabled)
                    Text("Calendar app").tag(CalendarSource.iCal)
                    if MicrosoftAuthService.isConfigured {
                        Text("Outlook").tag(CalendarSource.outlook)
                    }
                    Text("Claude CLI").tag(CalendarSource.claudeCLI)
                }
                .pickerStyle(.segmented)
            }

            switch settings.effectiveCalendarSource {
            case .iCal:
                if calendarStatus == .fullAccess {
                    SettingsRow("Calendars", caption: "Only these calendars are used for matching and the meeting picker.") {
                        HStack(spacing: 8) {
                            if settings.selectedICalCalendarIDs?.isEmpty == true {
                                SettingsStatusPill("None selected", kind: .warning)
                                    .help("iCal matching will return no meetings.")
                            } else if unavailableICalCalendarCount > 0 {
                                SettingsStatusPill(verbatim: "\(unavailableICalCalendarCount) unavailable", kind: .warning)
                                    .help(unavailableICalCalendarMessage)
                            }
                            calendarMenu
                        }
                    }
                } else {
                    SettingsRow("Calendar access", caption: "Allow calendar access on the Permissions page.") {
                        SettingsStatusPill("Not allowed", kind: .warning)
                    }
                }

            case .outlook:
                if microsoftAuthService.isSignedIn {
                    SettingsRow(verbatim: microsoftAuthService.accountInfo?.displayName ?? "Microsoft account",
                                caption: microsoftAuthService.accountInfo?.email,
                                systemImage: "person.crop.circle") {
                        Button("Sign out") { microsoftAuthService.signOut() }
                            .buttonStyle(.settingsSecondary)
                    }
                } else {
                    SettingsRow(verbatim: "Microsoft account", caption: outlookSignInError, systemImage: "person.crop.circle") {
                        Button("Sign in with Microsoft") {
                            outlookSignInError = nil
                            Task { @MainActor in
                                do {
                                    try await microsoftAuthService.signIn()
                                } catch {
                                    outlookSignInError = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.settingsPrimary)
                    }
                }

            case .claudeCLI, .disabled:
                EmptyView()
            }
        }
        .onAppear {
            reloadICalCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            reloadICalCalendars()
        }

        if SettingsCalendarVisibility.showsClaudeCLI(source: settings.effectiveCalendarSource, request: searchRequest) {
            SettingsCalendarCLISection()
        }

        if SettingsCalendarVisibility.showsMatching(source: settings.effectiveCalendarSource, request: searchRequest) {
            SettingsCard("Meeting matching", section: .meetingMatching) {
                SettingsRow("Match window",
                            caption: "Overlapping meetings match automatically. The window also allows nearby starts.") {
                    Picker("Match window", selection: $settings.calendarMatchWindowMinutes) {
                        ForEach(AppSettings.calendarMatchWindowOptions, id: \.self) { minutes in
                            if minutes == 0 {
                                Text("Only overlapping").tag(minutes)
                            } else {
                                Text("\(minutes) minutes").tag(minutes)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                }
                SettingsRow("Show all meetings from that day", caption: "Adds the rest of the day to the meeting picker.") {
                    Toggle("Show all meetings from that day", isOn: $settings.showAllMeetingsFromRecordingDay)
                }
            }
        }
    }

    private var calendarMenu: some View {
        @Bindable var settings = appSettings
        return Menu {
            // Toggles render as native checkmark items, so the state reaches VoiceOver.
            Toggle("All calendars", isOn: Binding(
                get: { settings.selectedICalCalendarIDs == nil },
                set: { if $0 { settings.selectedICalCalendarIDs = nil } }
            ))

            Divider()

            if availableICalCalendars.isEmpty {
                Text("No calendars available")
            } else {
                ForEach(availableICalCalendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { settings.selectedICalCalendarIDs?.contains(calendar.id) == true },
                        set: { _ in toggleICalCalendar(calendar.id) }
                    )) {
                        Label {
                            Text(calendar.displayName)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(calendar.color)
                        }
                    }
                }
            }
        } label: {
            Text(iCalCalendarSelectionSummary)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private var iCalCalendarSelectionSummary: String {
        guard let selected = appSettings.selectedICalCalendarIDs else {
            return "All calendars"
        }
        guard !selected.isEmpty else { return "No calendars" }
        if selected.count == 1,
           let calendar = availableICalCalendars.first(where: { selected.contains($0.id) }) {
            return calendar.title
        }
        return selected.count == 1 ? "1 calendar" : "\(selected.count) calendars"
    }

    private var unavailableICalCalendarCount: Int {
        guard let selected = appSettings.selectedICalCalendarIDs else { return 0 }
        let available = Set(availableICalCalendars.map(\.id))
        return selected.subtracting(available).count
    }

    private var unavailableICalCalendarMessage: String {
        let count = unavailableICalCalendarCount
        let noun = count == 1 ? "calendar is" : "calendars are"
        return "\(count) selected \(noun) unavailable and won’t provide meetings."
    }

    private func toggleICalCalendar(_ id: String) {
        var selected = appSettings.selectedICalCalendarIDs ?? []
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        appSettings.selectedICalCalendarIDs = selected
    }

    private func reloadICalCalendars() {
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        guard calendarStatus == .fullAccess else {
            availableICalCalendars = []
            return
        }

        let store = EKEventStore()
        availableICalCalendars = store.calendars(for: .event)
            .map { calendar in
                ICalCalendarOption(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source.title,
                    color: Color(nsColor: calendar.color)
                )
            }
            .sorted { lhs, rhs in
                let sourceOrder = lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle)
                if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
}

private struct ICalCalendarOption: Identifiable {
    let id: String
    let title: String
    let sourceTitle: String
    let color: Color

    var displayName: String {
        "\(title) — \(sourceTitle)"
    }
}
