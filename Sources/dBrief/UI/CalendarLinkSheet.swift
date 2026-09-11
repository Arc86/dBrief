import SwiftUI

struct CalendarLinkSheet: View {
    let recording: Recording
    let hasTranscript: Bool
    var dismissAction: (() -> Void)? = nil
    @Environment(RecordingManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var events: [CalendarEvent] = []
    @State private var selectedID: String?
    @State private var updateTitle = false
    @State private var updateParticipants = false
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    @State private var showAnalysis = false

    private var selected: CalendarEvent? { events.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(saved ? "Calendar meeting linked" : "Link calendar meeting")
                .font(.title2.weight(.semibold))
            if saved {
                Text("The meeting context is saved. Existing generated results are kept until you choose to regenerate them.")
                Text("Re-run AI analysis to update the summary, action items, and tags using the meeting agenda and participants. Review speaker names in the transcript using the meeting attendees.")
                    .foregroundStyle(.secondary)
                Text("Previously exported files and content sent to integrations are not updated automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { close() }.keyboardShortcut(.cancelAction)
                    if hasTranscript {
                        Button("Re-run AI analysis…") { showAnalysis = true }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                Text("Meetings from the recording’s original day, with likely matches first.")
                    .foregroundStyle(.secondary)
                if loading {
                    ProgressView("Loading meetings…")
                } else if events.isEmpty {
                    Text("No meetings were found. Check the selected calendars and calendar access in Settings, then try again.")
                    Button("Try Again") { Task { await load() } }
                } else {
                    Picker("Meeting", selection: $selectedID) {
                        Text("Choose a meeting").tag(String?.none)
                        ForEach(events) { event in
                            Text(label(event)).tag(Optional(event.id))
                        }
                    }
                    if let event = selected {
                        if !event.attendeeNames.isEmpty {
                            Text(event.attendeeNames.joined(separator: ", ")).font(.callout)
                        }
                        if !event.body.isEmpty {
                            ScrollView { Text(event.body).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                                .frame(maxHeight: 130)
                        }
                        Toggle("Use meeting title", isOn: $updateTitle)
                        Toggle("Replace participants with meeting attendees", isOn: $updateParticipants)
                        Text("The full calendar context is saved even when these fields are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button("Link Meeting") { save() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(selected == nil || loading || saving)
                    if saving { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(24).frame(width: 540)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .task { await load() }
        .sheet(isPresented: $showAnalysis, onDismiss: { close() }) {
            ReprocessingSheet(recording: recording, operation: .analysis)
        }
    }

    private func close() {
        if let dismissAction { dismissAction() }
        else { dismiss() }
    }

    private func label(_ event: CalendarEvent) -> String {
        let title = event.title.isEmpty ? "Untitled meeting" : event.title
        return event.isAllDay ? "\(title) — All day" : "\(title) — \(event.startDate.formatted(date: .omitted, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened))"
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            events = try await manager.calendarEventsForLinking(recording)
            selectedID = events.first { $0.id == recording.calendarEvent?.id }?.id
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
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
