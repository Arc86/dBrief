import Foundation

enum LibraryRecordingStatus: String, Codable, CaseIterable, Sendable {
    case queued, failed, incomplete, unprocessed, done

    var title: String { rawValue.capitalized }

    static func resolve(job: LibraryJobSummary?, queued: Bool, transcript: Bool, malformed: Bool) -> Self {
        if let job, !job.dismissed {
            switch job.status {
            case .queued: return .queued
            case .failed: return .failed
            case .completed: return malformed ? .incomplete : .done
            default: return .incomplete
            }
        }
        if queued { return .queued }
        if malformed { return .incomplete }
        return transcript ? .done : .unprocessed
    }
}

struct LibraryJobSummary: Codable, Sendable {
    let audioPath: String
    let updatedAt: Date
    let status: PersistedProcessingJob.Status
    let dismissed: Bool
    let associatedApp: String

    init?(_ job: PersistedProcessingJob) {
        guard job.version == PersistedProcessingJob.currentVersion else { return nil }
        self.init(RecoveryQueueEntry.JobFacts(job))
    }

    init?(_ job: RecoveryQueueEntry.JobFacts) {
        guard let path = job.audioPath else { return nil }
        audioPath = path
        updatedAt = job.updatedAt
        status = job.status
        dismissed = job.dismissedFromQueue == true
        associatedApp = job.associatedApp
    }
}

struct LibraryDocument {
    static let extensions = ["json", "transcript.json", "richtranscript.json", "insights.json", "queue.json", "md", "reprocessing.json"]
    let item: RecordingBrowserItem
    let body: String
    let sourceReads: Int
    let unfinishedActions: Int
    let processedAt: Date?
    let people: [LibraryPerson]

    init(entry: RecordingFileEntry, job: LibraryJobSummary?, read: (URL) throws -> Data) throws {
        let base = entry.url.deletingPathExtension()
        var reads = 0
        var malformed = false
        func data(_ ext: String) throws -> Data? {
            let url = base.appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            reads += 1
            return try read(url)
        }
        func object(_ ext: String) throws -> [String: Any]? {
            guard let bytes = try data(ext) else { return nil }
            guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                malformed = true
                return nil
            }
            return value
        }
        let metadata = try object("json") ?? [:]
        let raw = try object("transcript.json")
        let rich = try object("richtranscript.json")
        let insights = try object("insights.json") ?? [:]
        let queue = try object("queue.json")
        let markdown = try data("md").map { String(decoding: $0, as: UTF8.self) } ?? ""
        let richSegments = rich?["segments"] as? [[String: Any]]
        let rawSegments = raw?["segments"] as? [[String: Any]]
        let transcript = richSegments?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            ?? raw?["text"] as? String
            ?? rawSegments?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        let participants = metadata["participants"] as? [String] ?? []
        let attendees = metadata["calendarAttendees"] as? [String] ?? []
        let speakers = (rich?["speakerLabels"] as? [[String: Any]])?.compactMap { $0["displayName"] as? String } ?? []
        let tags = insights["tags"] as? [String] ?? []
        let actions = insights["actionItems"] as? [String] ?? []
        let completed = Set(insights["completedActionItems"] as? [String] ?? [])
        unfinishedActions = actions.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !completed.contains($0)
        }.count
        let provenance = try object("reprocessing.json")
        if let stamp = provenance?["completion"] ?? metadata["lastProcessingCompletion"],
           let bytes = try? JSONSerialization.data(withJSONObject: stamp),
           let value = try? JSONDecoder().decode(ProcessingCompletionStamp.self, from: bytes) {
            processedAt = value.completedAt
        } else { processedAt = nil }
        let labels = rich?["speakerLabels"] as? [[String: Any]] ?? []
        let meID = rich?["meSpeakerId"] as? String
        let selfNames = labels.filter { meID != nil && ($0["id"] as? String) == meID }
            .compactMap { $0["displayName"] as? String }
        people = LibraryPerson.normalized(participants + attendees + speakers, excluding: selfNames)
        let isoDate = metadata["dateISO8601"] as? String ?? ""
        let date = ISO8601DateFormatter().date(from: isoDate) ?? entry.createdAt
        let title = metadata["generatedTitle"] as? String ?? insights["generatedTitle"] as? String
        let hasRaw = raw?["text"] is String || rawSegments != nil
        let hasRich = richSegments != nil
        if raw != nil && !hasRaw || rich != nil && !hasRich { malformed = true }
        let status = LibraryRecordingStatus.resolve(job: job, queued: queue != nil,
            transcript: hasRaw || hasRich, malformed: malformed)
        item = RecordingBrowserItem(url: entry.url, name: base.lastPathComponent,
            date: date, size: entry.size, duration: metadata["durationSeconds"] as? Double ?? 0,
            hasTranscript: hasRaw, hasRichTranscript: hasRich, generatedTitle: title,
            meetingNames: PersonName.displayList(participants + attendees), libraryStatus: status)
        // Rich sidecars contain user edits. Do not index raw originalText or the
        // derived Markdown transcript alongside them (that resurrects old words).
        let fallbackMarkdown = hasRaw || hasRich ? "" : markdown
        body = ([item.title, item.name, metadata["meetingTitle"] as? String ?? "",
                 transcript, insights["summary"] as? String ?? "", isoDate,
                 ISO8601DateFormatter().string(from: date), metadata["associatedApp"] as? String ?? "",
                 job?.associatedApp ?? "", fallbackMarkdown] + participants + attendees + speakers + tags + actions)
            .joined(separator: "\n")
        sourceReads = reads
    }
}
