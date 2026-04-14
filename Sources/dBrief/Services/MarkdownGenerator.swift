import Foundation

struct MarkdownGenerator {
    @MainActor
    func generate(
        recording: Recording,
        outputFolder: URL,
        transcriptionEndpoint: Endpoint?,
        aiEndpoint: Endpoint?,
        includeTranscript: Bool = false
    ) throws -> URL {
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let title = generatedTitle(for: recording)
        let datePrefix = formatDateOnly(recording.date)
        let outputURL = outputFolder.appendingPathComponent("\(datePrefix) - \(title).md")

        let content = buildMarkdown(
            recording: recording,
            title: title,
            transcriptionEndpoint: transcriptionEndpoint,
            aiEndpoint: aiEndpoint,
            includeTranscript: includeTranscript
        )

        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    @MainActor
    private func buildMarkdown(
        recording: Recording,
        title: String,
        transcriptionEndpoint: Endpoint?,
        aiEndpoint: Endpoint?,
        includeTranscript: Bool
    ) -> String {
        var lines: [String] = []

        // YAML Frontmatter
        lines.append("---")
        lines.append("title: \"\(title)\"")
        lines.append("date: \(formatDate(recording.date))")

        if let tags = recording.tags, !tags.isEmpty {
            lines.append("tags:")
            for tag in tags {
                let sanitized = tag.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
                    .lowercased()
                lines.append("  - \(sanitized)")
            }
        }

        lines.append("duration: \"\(recording.formattedDuration)\"")
        lines.append("audio_file: \"[[\(recording.fileURL.lastPathComponent)]]\"")

        if let speakerCount = recording.transcription?.speakerCount, speakerCount > 1 {
            lines.append("speakers: \(speakerCount)")
        }

        if let transcriptionEndpoint {
            lines.append("transcription_model: \"\(transcriptionEndpoint.modelName)\"")
        }
        if let aiEndpoint {
            lines.append("ai_model: \"\(aiEndpoint.modelName)\"")
        }
        if let sentiment = recording.sentiment {
            lines.append("sentiment: \"\(sentiment)\"")
        }
        if recording.associatedApp != nil {
            lines.append("type: \"meeting\"")
        } else {
            lines.append("type: \"recording\"")
        }

        lines.append("---")
        lines.append("")

        // Summary first for Obsidian readability
        if let summary = recording.summary {
            lines.append("## 📝 Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        // Action Items section
        if let actionItems = recording.actionItems, !actionItems.isEmpty {
            lines.append("## ✅ Action Items")
            lines.append("")
            for item in actionItems {
                lines.append("- [ ] \(item)")
            }
            lines.append("")
        }

        // Tags & Sentiment section
        if recording.tags != nil || recording.sentiment != nil {
            lines.append("## 🏷️ Tags")
            lines.append("")
            if let tags = recording.tags, !tags.isEmpty {
                let normalized = tags.map {
                    "#\($0.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased())"
                }
                lines.append(normalized.joined(separator: " "))
            }
            lines.append("")
            if let sentiment = recording.sentiment {
                lines.append("**Sentiment:** \(sentiment)")
                lines.append("")
            }
        }

        // Transcript last so notes start with insights
        if includeTranscript, let transcription = recording.transcription {
            lines.append("---")
            lines.append("## 💬 Transcript")
            lines.append("")

            let speakerLabels = recording.richTranscript?.speakerLabels ?? []
            if transcription.segments.isEmpty {
                lines.append(transcription.text)
            } else {
                for segment in transcription.segments {
                    let timestamp = formatTimestamp(segment.start)
                    let text = segment.text.trimmingCharacters(in: .whitespaces)
                    if let speakerId = segment.speaker {
                        let displayName = speakerLabels.first(where: { $0.id == speakerId })?.displayName ?? speakerId
                        lines.append("**[\(timestamp)] \(displayName):** \(text)")
                    } else {
                        lines.append("**[\(timestamp)]** \(text)")
                    }
                    lines.append("")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatDateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @MainActor
    private func generatedTitle(for recording: Recording) -> String {
        // Prefer AI-generated title
        if let aiTitle = recording.generatedTitle, !aiTitle.isEmpty {
            return sanitizeFileNameComponent(aiTitle)
        }
        // Fallback to extracting from summary/transcription text
        if let summary = recording.summary {
            if let title = titleFromText(summary) {
                return title
            }
        }
        if let transcription = recording.transcription?.text {
            if let title = titleFromText(transcription) {
                return title
            }
        }
        return "Recording"
    }

    private func titleFromText(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.lowercased().contains("detailed summary in the same language as the transcript") {
            return nil
        }

        let firstLine = cleaned.split(separator: ".").first.map(String.init) ?? cleaned
        let withoutBullets = firstLine.replacingOccurrences(of: #"^\s*[-•]\s+"#, with: "", options: .regularExpression)
        let collapsed = withoutBullets.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let words = collapsed.split(separator: " ")
        let limited = words.prefix(10).joined(separator: " ")
        return sanitizeFileNameComponent(String(limited))
    }

    private func sanitizeFileNameComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = value
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { return "Recording" }
        if sanitized.count > 80 {
            let index = sanitized.index(sanitized.startIndex, offsetBy: 80)
            return String(sanitized[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sanitized
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
