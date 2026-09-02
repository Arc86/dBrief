import AppKit
import EventKit
import Foundation
import os

private let integrationLog = Logger.integrations

actor IntegrationDispatchService {
    private let webhookPayloadBuilder = WebhookPayloadBuilder()
    private let reminderStore = EKEventStore()

    func dispatch(
        recording: Recording,
        settings: AppSettings,
        generatedMarkdownURL: URL?
    ) async -> [IntegrationDispatchResult] {
        let snapshot = await MainActor.run { IntegrationSettingsSnapshot(settings: settings) }
        let recordingSnapshot = await MainActor.run { RecordingSnapshot(recording: recording) }
        let bundle = buildBundle(recording: recordingSnapshot, markdownURL: generatedMarkdownURL)

        var results: [IntegrationDispatchResult] = []

        if snapshot.config.appleNotes.enabled {
            results.append(await perform(.appleNotes) {
                try self.sendToAppleNotes(bundle: bundle, config: snapshot.config.appleNotes)
            })
        }

        if snapshot.config.appleReminders.enabled {
            if bundle.actionItems.isEmpty {
                results.append(
                    IntegrationDispatchResult(
                        destination: .appleReminders,
                        status: .skipped,
                        message: "No action items",
                        remoteID: nil
                    )
                )
            } else {
                results.append(await perform(.appleReminders) {
                    try await self.sendToAppleReminders(bundle: bundle, config: snapshot.config.appleReminders)
                })
            }
        }

        if IntegrationDestination.available.contains(.notion), snapshot.config.notion.enabled {
            results.append(await perform(.notion) {
                try await self.sendToNotion(bundle: bundle, config: snapshot.config.notion, token: snapshot.notionToken)
            })
        }

        if IntegrationDestination.available.contains(.evernote), snapshot.config.evernote.enabled {
            results.append(await perform(.evernote) {
                try await self.sendToEvernote(bundle: bundle, config: snapshot.config.evernote, token: snapshot.evernoteToken)
            })
        }

        if IntegrationDestination.available.contains(.googleKeep), snapshot.config.googleKeep.enabled {
            results.append(await perform(.googleKeep) {
                try await self.sendToGoogleKeep(bundle: bundle, config: snapshot.config.googleKeep, token: snapshot.googleKeepToken)
            })
        }

        if IntegrationDestination.available.contains(.oneNote), snapshot.config.oneNote.enabled {
            results.append(await perform(.oneNote) {
                try await self.sendToOneNote(bundle: bundle, config: snapshot.config.oneNote, token: snapshot.oneNoteToken)
            })
        }

        if snapshot.config.webhook.enabled {
            results.append(await perform(.webhook) {
                try await self.sendToWebhook(recording: recordingSnapshot, bundle: bundle, config: snapshot.config.webhook)
            })
        }

        return results
    }

    func testConnection(destination: IntegrationDestination, settings: AppSettings) async throws {
        guard IntegrationDestination.available.contains(destination) else {
            throw IntegrationError.unsupported("\(destination.displayName) is not available")
        }
        let snapshot = await MainActor.run { IntegrationSettingsSnapshot(settings: settings) }

        switch destination {
        case .appleNotes:
            _ = try runAppleScript("tell application \"Notes\" to return \"ok\"")
        case .appleReminders:
            try await assertRemindersPermission()
        case .notion:
            try await testHTTPBearerConnection(urlString: "https://api.notion.com/v1/users/me", token: snapshot.notionToken, extraHeaders: ["Notion-Version": "2022-06-28"])
        case .evernote:
            let base = snapshot.config.evernote.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            try await testHTTPBearerConnection(urlString: "\(base)/v1/user", token: snapshot.evernoteToken, extraHeaders: [:])
        case .googleKeep:
            try await testHTTPBearerConnection(urlString: "\(snapshot.config.googleKeep.apiBaseURL)/notes?pageSize=1", token: snapshot.googleKeepToken, extraHeaders: [:])
        case .oneNote:
            try await testHTTPBearerConnection(urlString: "\(snapshot.config.oneNote.graphBaseURL)/me/onenote/notebooks", token: snapshot.oneNoteToken, extraHeaders: [:])
        case .webhook:
            guard URL(string: snapshot.config.webhook.url) != nil else {
                throw IntegrationError.invalidURL(snapshot.config.webhook.url)
            }
        case .obsidian:
            break
        }
    }

    private func perform(_ destination: IntegrationDestination, op: () async throws -> String?) async -> IntegrationDispatchResult {
        let start = Date()
        do {
            let remoteID = try await op()
            let latency = Date().timeIntervalSince(start)
            integrationLog.info("Integration success: \(destination.rawValue, privacy: .public) in \(latency, privacy: .public)s")
            return IntegrationDispatchResult(destination: destination, status: .success, message: "Sent", remoteID: remoteID)
        } catch {
            let latency = Date().timeIntervalSince(start)
            integrationLog.error("Integration failure: \(destination.rawValue, privacy: .public) in \(latency, privacy: .public)s")
            return IntegrationDispatchResult(destination: destination, status: .failed, message: error.localizedDescription, remoteID: nil)
        }
    }

    private func buildBundle(recording: RecordingSnapshot, markdownURL: URL?) -> IntegrationContentBundle {
        let title = recording.generatedTitle?.isEmpty == false ? recording.generatedTitle! : recording.fileName
        let markdown: String?
        if let markdownURL {
            markdown = try? String(contentsOf: markdownURL, encoding: .utf8)
        } else {
            markdown = nil
        }

        return IntegrationContentBundle(
            title: title,
            createdAt: recording.date,
            durationSeconds: recording.duration,
            audioFileURL: recording.fileURL,
            transcript: recording.transcript,
            summary: recording.summary,
            actionItems: recording.actionItems,
            tags: recording.tags,
            sentiment: recording.sentiment,
            markdown: markdown,
            calendarEvent: recording.calendarEvent
        )
    }

    private func sendToAppleNotes(bundle: IntegrationContentBundle, config: AppleNotesConfig) throws -> String? {
        let content = renderPlainContent(bundle: bundle, fields: config.fields)
        let escapedTitle = escapeAppleScript(bundle.title)
        let escapedBody = escapeAppleScript(content)

        let script: String
        if !config.accountName.isEmpty, !config.folderName.isEmpty {
            let account = escapeAppleScript(config.accountName)
            let folder = escapeAppleScript(config.folderName)
            script = """
            tell application "Notes"
                tell folder "\(folder)" of account "\(account)"
                    make new note with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
                end tell
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                make new note with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
            end tell
            """
        }

        _ = try runAppleScript(script)
        return nil
    }

    private func sendToAppleReminders(bundle: IntegrationContentBundle, config: AppleRemindersConfig) async throws -> String? {
        try await assertRemindersPermission()

        let targetCalendar: EKCalendar
        if !config.listName.isEmpty,
           let match = reminderStore.calendars(for: .reminder).first(where: { $0.title == config.listName })
        {
            targetCalendar = match
        } else if let fallback = reminderStore.defaultCalendarForNewReminders() {
            targetCalendar = fallback
        } else {
            throw IntegrationError.executionFailed("No reminders list available")
        }

        var created = 0
        for item in bundle.actionItems where !item.isEmpty {
            let reminder = EKReminder(eventStore: reminderStore)
            reminder.title = item
            reminder.calendar = targetCalendar
            try reminderStore.save(reminder, commit: false)
            created += 1
        }
        try reminderStore.commit()
        return "\(created)"
    }

    private func sendToNotion(bundle: IntegrationContentBundle, config: NotionConfig, token: String) async throws -> String? {
        guard !token.isEmpty else {
            throw IntegrationError.missingConfiguration("Notion token is required")
        }
        guard !config.parentID.isEmpty else {
            throw IntegrationError.missingConfiguration("Notion parent ID is required")
        }

        guard let url = URL(string: "https://api.notion.com/v1/pages") else {
            throw IntegrationError.invalidURL("https://api.notion.com/v1/pages")
        }

        let titlePropertyName = config.titlePropertyName.isEmpty ? "Name" : config.titlePropertyName
        let parentType = config.parentType == .dataSource ? "data_source_id" : "page_id"

        let content = renderPlainContent(bundle: bundle, fields: config.fields)
        let lines = content.split(separator: "\n").map(String.init)
        let blocks: [[String: Any]] = lines.map { line in
            [
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [
                        [
                            "type": "text",
                            "text": ["content": line],
                        ],
                    ],
                ],
            ]
        }

        let payload: [String: Any] = [
            "parent": [parentType: config.parentID],
            "properties": [
                titlePropertyName: [
                    "title": [[
                        "type": "text",
                        "text": ["content": bundle.title],
                    ]],
                ],
            ],
            "children": blocks,
        ]

        let data = try await performJSONRequest(
            url: url,
            method: "POST",
            payload: payload,
            bearerToken: token,
            additionalHeaders: ["Notion-Version": "2022-06-28"],
            timeout: 30
        )

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }
        return nil
    }

    private func sendToEvernote(bundle: IntegrationContentBundle, config: EvernoteConfig, token: String) async throws -> String? {
        guard !token.isEmpty else {
            throw IntegrationError.missingConfiguration("Evernote token is required")
        }

        let base = config.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base)/v1/notes") else {
            throw IntegrationError.invalidURL(base)
        }

        let htmlBody = renderHTMLContent(bundle: bundle, fields: config.fields)
        var payload: [String: Any] = [
            "title": bundle.title,
            "content": htmlBody,
        ]
        if !config.notebookID.isEmpty {
            payload["notebookId"] = config.notebookID
        }

        let data = try await performJSONRequest(
            url: url,
            method: "POST",
            payload: payload,
            bearerToken: token,
            additionalHeaders: [:],
            timeout: 30
        )

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }
        return nil
    }

    private func sendToGoogleKeep(bundle: IntegrationContentBundle, config: GoogleKeepConfig, token: String) async throws -> String? {
        guard !token.isEmpty else {
            throw IntegrationError.missingConfiguration("Google Keep token is required")
        }

        let base = config.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base)/notes") else {
            throw IntegrationError.invalidURL(base)
        }

        let text = renderPlainContent(bundle: bundle, fields: config.fields)
        let payload: [String: Any] = [
            "title": bundle.title,
            "textContent": [
                "text": text,
            ],
        ]

        let data = try await performJSONRequest(
            url: url,
            method: "POST",
            payload: payload,
            bearerToken: token,
            additionalHeaders: [:],
            timeout: 30
        )

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String {
            return name
        }
        return nil
    }

    private func sendToOneNote(bundle: IntegrationContentBundle, config: OneNoteConfig, token: String) async throws -> String? {
        guard !token.isEmpty else {
            throw IntegrationError.missingConfiguration("OneNote token is required")
        }

        let base = config.graphBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = config.sectionID.isEmpty
            ? "\(base)/me/onenote/pages"
            : "\(base)/me/onenote/sections/\(config.sectionID)/pages"
        guard let url = URL(string: endpoint) else {
            throw IntegrationError.invalidURL(endpoint)
        }

        let html = renderOneNoteHTML(bundle: bundle, fields: config.fields)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/html", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = Data(html.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IntegrationError.executionFailed("OneNote returned invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw IntegrationError.transport(statusCode: http.statusCode, body: body)
        }

        return nil
    }

    private func sendToWebhook(recording: RecordingSnapshot, bundle: IntegrationContentBundle, config: WebhookConfig) async throws -> String? {
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw IntegrationError.invalidURL(config.url)
        }

        let includeAudio = config.fields.contains(.audio)
        let payload = try webhookPayloadBuilder.build(
            recordingID: recording.id,
            fileName: recording.fileURL.lastPathComponent,
            createdAt: recording.date,
            durationSeconds: recording.duration,
            bundle: bundle,
            fields: config.fields,
            includeAudio: includeAudio
        )

        // A multipart body is staged on disk (never held in RAM); the same file
        // serves every retry and is removed when dispatch finishes.
        defer {
            if case let .file(bodyURL) = payload.body {
                try? FileManager.default.removeItem(at: bodyURL)
            }
        }

        var attempt = 0
        while true {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = max(5, config.timeoutSeconds)
                request.setValue(payload.contentType, forHTTPHeaderField: "Content-Type")
                for header in config.headers where !header.key.isEmpty {
                    request.setValue(header.value, forHTTPHeaderField: header.key)
                }

                let data: Data
                let response: URLResponse
                switch payload.body {
                case .data(let body):
                    request.httpBody = body
                    (data, response) = try await URLSession.shared.data(for: request)
                case .file(let bodyURL):
                    (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
                }
                guard let http = response as? HTTPURLResponse else {
                    throw IntegrationError.executionFailed("Webhook returned invalid response")
                }
                guard (200...299).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw IntegrationError.transport(statusCode: http.statusCode, body: body)
                }
                return nil
            } catch {
                if attempt >= max(0, config.retryCount) {
                    throw error
                }
                attempt += 1
            }
        }
    }

    private func performJSONRequest(
        url: URL,
        method: String,
        payload: [String: Any],
        bearerToken: String,
        additionalHeaders: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        additionalHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IntegrationError.executionFailed("Request returned invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw IntegrationError.transport(statusCode: http.statusCode, body: body)
        }
        return data
    }

    private func testHTTPBearerConnection(
        urlString: String,
        token: String,
        extraHeaders: [String: String]
    ) async throws {
        guard !token.isEmpty else {
            throw IntegrationError.missingConfiguration("Token is required")
        }
        guard let url = URL(string: urlString) else {
            throw IntegrationError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IntegrationError.executionFailed("Connection test returned invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw IntegrationError.transport(statusCode: http.statusCode, body: body)
        }
    }

    private func assertRemindersPermission() async throws {
        let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            reminderStore.requestFullAccessToReminders { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: granted)
            }
        }

        guard granted else {
            throw IntegrationError.permissionDenied("Reminders permission denied")
        }
    }

    private func runAppleScript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let reason = String(data: errorData, encoding: .utf8) ?? "AppleScript failed"
            throw IntegrationError.executionFailed(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func renderPlainContent(bundle: IntegrationContentBundle, fields: [DeliveryField]) -> String {
        var parts: [String] = []

        if fields.contains(.transcript), let transcript = bundle.transcript {
            parts.append("Transcription\n\(transcript)")
        }
        if fields.contains(.summary), let summary = bundle.summary {
            parts.append("Summary\n\(summary)")
        }
        if fields.contains(.actionItems), !bundle.actionItems.isEmpty {
            parts.append("Action Items\n\(bundle.actionItems.map { "- \($0)" }.joined(separator: "\n"))")
        }
        if fields.contains(.tags), !bundle.tags.isEmpty {
            parts.append("Tags\n\(bundle.tags.joined(separator: ", "))")
        }
        if fields.contains(.sentiment), let sentiment = bundle.sentiment {
            parts.append("Sentiment\n\(sentiment)")
        }
        if fields.contains(.markdown), let markdown = bundle.markdown {
            parts.append("Markdown\n\(markdown)")
        }
        if fields.contains(.meetingInfo), let event = bundle.calendarEvent {
            if let meeting = Self.renderMeetingInfo(event) {
                parts.append(meeting)
            }
        }

        if parts.isEmpty {
            return "No selected fields contained data."
        }
        return parts.joined(separator: "\n\n")
    }

    /// Renders calendar-derived meeting context (organizer, attendees + emails, modality,
    /// location, agenda) as a plain-text block. Returns nil when there's nothing to show.
    private static func renderMeetingInfo(_ event: CalendarEvent) -> String? {
        var lines: [String] = []
        if let organizer = event.organizer {
            let email = organizer.email.map { " <\($0)>" } ?? ""
            lines.append("Organizer: \(organizer.name)\(email)")
        }
        if !event.attendees.isEmpty {
            let names = event.attendees.map { person -> String in
                if let email = person.email, !email.isEmpty { return "\(person.name) <\(email)>" }
                return person.name
            }
            lines.append("Attendees: \(names.joined(separator: ", "))")
        }
        if event.modality != "unknown" {
            lines.append("Modality: \(event.modality)")
        }
        if let location = event.location, !location.isEmpty {
            lines.append("Location: \(location)")
        }
        let agenda = event.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !agenda.isEmpty {
            lines.append("Agenda:\n\(agenda)")
        }
        guard !lines.isEmpty else { return nil }
        return "Meeting Info\n\(lines.joined(separator: "\n"))"
    }

    private func renderHTMLContent(bundle: IntegrationContentBundle, fields: [DeliveryField]) -> String {
        let plain = renderPlainContent(bundle: bundle, fields: fields)
        let escaped = plain
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br/>")
        return "<div>\(escaped)</div>"
    }

    private func renderOneNoteHTML(bundle: IntegrationContentBundle, fields: [DeliveryField]) -> String {
        let plain = renderPlainContent(bundle: bundle, fields: fields)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br/>")

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <title>\(bundle.title)</title>
          <meta name="created" content="\(ISO8601DateFormatter().string(from: bundle.createdAt))" />
        </head>
        <body>
          <h1>\(bundle.title)</h1>
          <p>\(plain)</p>
        </body>
        </html>
        """
    }

    private func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

private struct IntegrationSettingsSnapshot: Sendable {
    let config: IntegrationSettings
    let notionToken: String
    let evernoteToken: String
    let googleKeepToken: String
    let oneNoteToken: String

    @MainActor
    init(settings: AppSettings) {
        self.config = settings.integrations
        self.notionToken = settings.notionToken
        self.evernoteToken = settings.evernoteToken
        self.googleKeepToken = settings.googleKeepToken
        self.oneNoteToken = settings.oneNoteToken
    }
}

private struct RecordingSnapshot: Sendable {
    let id: UUID
    let date: Date
    let fileURL: URL
    let duration: TimeInterval
    let generatedTitle: String?
    let transcript: String?
    let summary: String?
    let actionItems: [String]
    let tags: [String]
    let sentiment: String?
    let fileName: String
    let calendarEvent: CalendarEvent?

    @MainActor
    init(recording: Recording) {
        self.id = recording.id
        self.date = recording.date
        self.fileURL = recording.fileURL
        self.duration = recording.duration
        self.generatedTitle = recording.generatedTitle
        self.transcript = recording.transcription?.text
        self.summary = recording.summary
        self.actionItems = recording.actionItems ?? []
        self.tags = recording.tags ?? []
        self.sentiment = recording.sentiment
        self.fileName = recording.fileName
        self.calendarEvent = recording.calendarEvent
    }
}
