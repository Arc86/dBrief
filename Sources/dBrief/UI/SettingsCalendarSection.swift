import AppKit
import Combine
import EventKit
import SwiftUI

struct SettingsCalendarSection: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(MicrosoftAuthService.self) private var microsoftAuthService

    @State private var outlookSignInError: String?
    @State private var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var availableICalCalendars: [ICalCalendarOption] = []

    var body: some View {
        @Bindable var settings = appSettings
        Section("Calendar", settingsSearch: .calendar) {
            // Display the coerced value so the selection always matches a rendered
            // row (a stale `.outlook` shows as Off while Outlook is hidden); writes
            // persist the raw choice and self-restore once a client ID is configured.
            Picker("Source", selection: Binding(
                get: { settings.effectiveCalendarSource },
                set: { settings.calendarSource = $0 }
            )) {
                Text("Off").tag(CalendarSource.disabled)
                Text("iCal").tag(CalendarSource.iCal)
                if MicrosoftAuthService.isConfigured {
                    Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
                }
            }

            switch settings.effectiveCalendarSource {
            case .iCal:
                if calendarStatus == .fullAccess {
                    Text("Looks up the matching calendar event when a recording stops and pre-fills title, participants, and agenda context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Calendars") {
                        Menu {
                            Button {
                                settings.selectedICalCalendarIDs = nil
                            } label: {
                                if settings.selectedICalCalendarIDs == nil {
                                    Label("All Calendars", systemImage: "checkmark")
                                } else {
                                    Text("All Calendars")
                                }
                            }

                            Divider()

                            if availableICalCalendars.isEmpty {
                                Text("No calendars available")
                            } else {
                                ForEach(availableICalCalendars) { calendar in
                                    Button {
                                        toggleICalCalendar(calendar.id)
                                    } label: {
                                        let isSelected = settings.selectedICalCalendarIDs?
                                            .contains(calendar.id) == true
                                        Label {
                                            Text(calendar.displayName)
                                        } icon: {
                                            Image(systemName: isSelected ? "checkmark" : "circle.fill")
                                                .foregroundStyle(isSelected ? Color.primary : calendar.color)
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(iCalCalendarSelectionSummary)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Only events from the selected calendars are considered for automatic matching and the post-recording Meeting picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.selectedICalCalendarIDs?.isEmpty == true {
                        Label(
                            "No calendars selected. iCal matching will return no meetings.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else if unavailableICalCalendarCount > 0 {
                        Label(
                            unavailableICalCalendarMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else {
                    Text("Grant Calendar access in the Permissions tab to enable this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .outlook:
                if microsoftAuthService.isSignedIn {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(microsoftAuthService.accountInfo?.displayName ?? "Microsoft Account")
                                .fontWeight(.medium)
                            Text(microsoftAuthService.accountInfo?.email ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign out") {
                            microsoftAuthService.signOut()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
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
                        .buttonStyle(.borderedProminent)
                        if let error = outlookSignInError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

            case .disabled:
                EmptyView()
            }

            if settings.effectiveCalendarSource != .disabled {
                Picker("Automatic match window", selection: $settings.calendarMatchWindowMinutes) {
                    ForEach(AppSettings.calendarMatchWindowOptions, id: \.self) { minutes in
                        if minutes == 0 {
                            Text("Only overlapping").tag(minutes)
                        } else {
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                }
                Text("Automatically links overlapping events and non-overlapping events whose start time is within the selected window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Show all meetings from the recording day",
                    isOn: $settings.showAllMeetingsFromRecordingDay
                )
                Text("Adds the day’s other calendar events to the post-recording Meeting picker. Events outside the automatic match window are never selected automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.clear)
        .onAppear {
            reloadICalCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            reloadICalCalendars()
        }
    }

    private var iCalCalendarSelectionSummary: String {
        guard let selected = appSettings.selectedICalCalendarIDs else {
            return "All Calendars"
        }
        guard !selected.isEmpty else { return "No Calendars" }
        if selected.count == 1,
           let calendar = availableICalCalendars.first(where: { selected.contains($0.id) }) {
            return calendar.title
        }
        return "\(selected.count) Calendars"
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
