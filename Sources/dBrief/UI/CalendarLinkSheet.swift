import SwiftUI

struct CalendarLinkSheet: View {
    let recording: Recording
    let hasTranscript: Bool
    var dismissAction: (() -> Void)? = nil
    @Environment(RecordingManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var events: [CalendarEvent] = []
    @State private var meetingList: CalendarLinkMeetingList?
    @State private var selectedID: CalendarLinkSelectionID?
    @State private var retainedSelection: (CalendarLinkSelectionID, CalendarEvent)?
    @State private var updateTitle = false
    @State private var updateParticipants = false
    @State private var loading = true
    @State private var refreshing = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    @State private var showAnalysis = false

    private var selected: CalendarEvent? { events.first { selectionID(for: $0) == selectedID } }

    private func selectionID(for event: CalendarEvent) -> CalendarLinkSelectionID {
        if let retainedSelection, retainedSelection.1.id == event.id { return retainedSelection.0 }
        return meetingList?.selectionID(for: event) ?? .event(event.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(saved ? "Calendar meeting linked" : "Link calendar meeting")
                .uiFont(.title2.weight(.semibold))
            if saved {
                Text("The meeting context is saved. Existing generated results are kept until you choose to regenerate them.")
                Text("Re-run AI analysis to update the summary, action items, and tags using the meeting agenda and participants. Review speaker names in the transcript using the meeting attendees.")
                    .foregroundStyle(.secondary)
                Text("Previously exported files and content sent to integrations are not updated automatically.")
                    .uiFont(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { close() }.keyboardShortcut(.cancelAction)
                    if hasTranscript {
                        Button("Re-run AI analysis…") { showAnalysis = true }
                            .buttonStyle(.typographyProminent).keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                Text(meetingList.map {
                    "Meetings from \($0.recordingStart.formatted(date: .abbreviated, time: .omitted)), with likely matches first."
                } ?? "Meetings from the recording’s original day, with likely matches first.")
                    .foregroundStyle(.secondary)
                if loading && meetingList == nil {
                    ProgressView("Loading meetings…")
                } else {
                    if let status = meetingList?.statusMessage {
                        Label(status, systemImage: "calendar.badge.clock")
                            .uiFont(.callout).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if refreshing { ProgressView("Refreshing this date…").controlSize(.small) }
                    if events.isEmpty {
                        if let empty = meetingList?.emptyMessage {
                            Text(empty).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Meeting", selection: Binding(
                            get: { selectedID },
                            set: { selectedID = $0; if retainedSelection?.0 != $0 { retainedSelection = nil } }
                        )) {
                            Text("Choose a meeting").tag(Optional<CalendarLinkSelectionID>.none)
                            ForEach(events) { event in
                                Text(label(event)).tag(Optional(selectionID(for: event)))
                            }
                        }
                        if let event = selected {
                            if !event.attendeeNames.isEmpty {
                                Text(event.attendeeNames.joined(separator: ", ")).uiFont(.callout)
                            }
                            if !event.body.isEmpty {
                                ScrollView { Text(event.body).uiFont(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                                    .frame(maxHeight: 130)
                            }
                            Toggle("Use meeting title", isOn: $updateTitle)
                            Toggle("Replace participants with meeting attendees", isOn: $updateParticipants)
                            Text("The full calendar context is saved even when these fields are kept.")
                                .uiFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).uiFont(.callout).textSelection(.enabled) }
                HStack {
                    Button("Refresh this date") { startRefresh(force: true) }
                        .disabled(loading || refreshing || saving)
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button("Link Meeting") { save() }
                        .buttonStyle(.typographyProminent).keyboardShortcut(.defaultAction)
                        .disabled(selected == nil || saving)
                    if saving { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(24).frame(width: 540)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .task(id: recording.id) { await loadCached() }
        .onDisappear { refreshTask?.cancel(); requestID = UUID() }
        .sheet(isPresented: $showAnalysis, onDismiss: { close() }) {
            ReprocessingSheet(recording: recording, operation: .analysis)
        }
    }

    private func close() {
        refreshTask?.cancel()
        requestID = UUID()
        if let dismissAction { dismissAction() }
        else { dismiss() }
    }

    private func label(_ event: CalendarEvent) -> String {
        let title = event.title.isEmpty ? "Untitled meeting" : event.title
        return event.isAllDay ? "\(title) — All day" : "\(title) — \(event.startDate.formatted(date: .omitted, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened))"
    }

    private func loadCached() async {
        refreshTask?.cancel()
        refreshing = false
        let token = UUID()
        requestID = token
        loading = true
        error = nil
        do {
            let list = try await manager.cachedCalendarMeetingsForLinking(recording)
            guard requestID == token, !Task.isCancelled else { return }
            apply(list)
            if selectedID == nil, let prior = recording.calendarEvent,
               let match = events.first(where: { $0.id == prior.id }) {
                selectedID = selectionID(for: match)
            }
            loading = false
            if !list.cliDays.isEmpty { startRefresh(force: false) }
        } catch is CancellationError { }
        catch {
            guard requestID == token else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func startRefresh(force: Bool) {
        guard !refreshing else { return }
        let token = UUID()
        requestID = token
        refreshing = true
        refreshTask = Task { @MainActor in
            defer { if requestID == token { refreshing = false } }
            do {
                let list = try await manager.refreshCalendarMeetingsForLinking(recording, force: force)
                guard requestID == token, !Task.isCancelled else { return }
                apply(list)
                error = nil
            } catch is CancellationError { }
            catch {
                guard requestID == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(_ list: CalendarLinkMeetingList) {
        let oldSelection = selected
        let oldID = selectedID
        meetingList = list
        events = list.events
        retainedSelection = nil
        if let oldID, !events.contains(where: { list.selectionID(for: $0) == oldID }),
           let oldSelection {
            events.append(oldSelection)
            retainedSelection = (oldID, oldSelection)
        }
    }

    private func save() {
        guard let selected else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await manager.linkCalendar(selected, to: recording,
                    updateTitle: updateTitle, updateParticipants: updateParticipants)
                saved = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
