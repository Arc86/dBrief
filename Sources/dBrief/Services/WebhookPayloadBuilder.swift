import Foundation

struct WebhookPayload {
    let contentType: String
    let body: Data
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
            var multipart = MultipartFormData()
            let metadataData = try JSONSerialization.data(withJSONObject: metadata)
            multipart.addField(name: "metadata", value: String(data: metadataData, encoding: .utf8) ?? "{}")

            let audioData = try Data(contentsOf: bundle.audioFileURL)
            multipart.addFile(
                name: "audio_file",
                fileName: bundle.audioFileURL.lastPathComponent,
                contentType: Self.contentType(for: bundle.audioFileURL),
                data: audioData
            )

            return WebhookPayload(contentType: multipart.contentType, body: multipart.encode())
        }

        let body = try JSONSerialization.data(withJSONObject: metadata)
        return WebhookPayload(contentType: "application/json", body: body)
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

        return payload
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "ogg": "audio/ogg"
        case "m4a": "audio/m4a"
        default: "application/octet-stream"
        }
    }
}
