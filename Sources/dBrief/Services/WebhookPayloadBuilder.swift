import Foundation

struct WebhookPayload {
    enum Body {
        case data(Data)
        /// Multipart body staged on disk so the audio is never held in RAM;
        /// the sender uploads via `URLSession.upload(fromFile:)` and deletes
        /// the file when dispatch finishes.
        case file(URL)
    }

    let contentType: String
    let body: Body
}

struct WebhookPayloadBuilder {
    func build(
        recordingID: UUID,
        fileName: String,
        createdAt: Date,
        durationSeconds: TimeInterval,
        bundle: IntegrationContentBundle,
        fields: [DeliveryField],
        includeAudio: Bool
    ) throws -> WebhookPayload {
        let metadata = payloadDictionary(
            recordingID: recordingID,
            fileName: fileName,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            bundle: bundle,
            fields: fields
        )

        if includeAudio {
            // Stream the multipart body to a temp file — reading the audio into
            // Data and then encode()-copying it held the recording in memory
            // twice during dispatch.
            let boundary = UUID().uuidString
            let metadataData = try JSONSerialization.data(withJSONObject: metadata)
            let bodyURL = try Self.writeMultipartBodyFile(
                metadataJSON: metadataData,
                audioURL: bundle.audioFileURL,
                boundary: boundary
            )
            return WebhookPayload(
                contentType: "multipart/form-data; boundary=\(boundary)",
                body: .file(bodyURL)
            )
        }

        let body = try JSONSerialization.data(withJSONObject: metadata)
        return WebhookPayload(contentType: "application/json", body: .data(body))
    }

    /// Writes the exact byte layout `MultipartFormData.encode()` produces for a
    /// metadata field + audio file part, but streams the audio from disk in
    /// 1 MB chunks. `WebhookPayloadBuilderTests` locks the equivalence.
    static func writeMultipartBodyFile(metadataJSON: Data, audioURL: URL, boundary: String) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("webhook-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        do {
            return try writeMultipartBody(to: tempURL, metadataJSON: metadataJSON, audioURL: audioURL, boundary: boundary)
        } catch {
            // Don't leave a partial temp file behind if the audio read fails
            // mid-build — the caller's cleanup only runs once we return a URL.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private static func writeMultipartBody(to tempURL: URL, metadataJSON: Data, audioURL: URL, boundary: String) throws -> URL {
        let out = try FileHandle(forWritingTo: tempURL)
        defer { try? out.close() }

        var head = Data("--\(boundary)\r\n".utf8)
        head.append(Data("Content-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8))
        head.append(metadataJSON)
        head.append(Data("\r\n--\(boundary)\r\n".utf8))
        head.append(Data("Content-Disposition: form-data; name=\"audio_file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".utf8))
        head.append(Data("Content-Type: \(contentType(for: audioURL))\r\n\r\n".utf8))
        try out.write(contentsOf: head)

        let audio = try FileHandle(forReadingFrom: audioURL)
        defer { try? audio.close() }
        while let chunk = try audio.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }

        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return tempURL
    }

    func payloadDictionary(
        recordingID: UUID,
        fileName: String,
        createdAt: Date,
        durationSeconds: TimeInterval,
        bundle: IntegrationContentBundle,
        fields: [DeliveryField]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "recording_id": recordingID.uuidString,
            "file_name": fileName,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "duration_seconds": durationSeconds,
            "title": bundle.title,
        ]

        if fields.contains(.transcript), let transcript = bundle.transcript {
            payload["transcript"] = transcript
        }
        if fields.contains(.summary), let summary = bundle.summary {
            payload["summary"] = summary
        }
        if fields.contains(.tags), !bundle.tags.isEmpty {
            payload["tags"] = bundle.tags
        }
        if fields.contains(.sentiment), let sentiment = bundle.sentiment {
            payload["sentiment"] = sentiment
        }
        if fields.contains(.actionItems), !bundle.actionItems.isEmpty {
            payload["action_items"] = bundle.actionItems
        }
        if fields.contains(.markdown), let markdown = bundle.markdown {
            payload["markdown"] = markdown
        }
        if fields.contains(.meetingInfo), let event = bundle.calendarEvent {
            payload["meeting"] = Self.meetingDictionary(event)
        }

        return payload
    }

    /// Structured calendar metadata for webhook consumers: people (name + email),
    /// organizer, agenda, modality, location, scheduled window, external-party flag.
    private static func meetingDictionary(_ event: CalendarEvent) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var meeting: [String: Any] = [
            "title": event.title,
            "modality": event.modality,
            "scheduled_start": iso.string(from: event.startDate),
            "scheduled_end": iso.string(from: event.endDate),
            "attendees": event.attendees.map { person -> [String: Any] in
                var entry: [String: Any] = ["name": person.name]
                if let email = person.email { entry["email"] = email }
                return entry
            },
        ]
        if let organizer = event.organizer {
            var entry: [String: Any] = ["name": organizer.name]
            if let email = organizer.email { entry["email"] = email }
            meeting["organizer"] = entry
        }
        let agenda = event.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !agenda.isEmpty { meeting["agenda"] = agenda }
        if let location = event.location, !location.isEmpty { meeting["location"] = location }
        if event.organizer?.emailDomain != nil {
            meeting["external_participants"] = event.hasExternalParticipants
        }
        return meeting
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "ogg": "audio/ogg"
        case "m4a": "audio/m4a"
        case "flac": "audio/flac"
        default: "application/octet-stream"
        }
    }
}
