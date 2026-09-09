import Foundation

extension LibraryIndex {
    /// All predicates operate on a committed cache snapshot. Recording status
    /// applies to recording/people views; work views use recovery facts instead.
    /// Callers exclude the current processing job and capture IDs/audio URLs.
    nonisolated func smartResults(in folder: URL, view: LibrarySmartView, text: String = "",
                                 status: LibraryRecordingStatus? = nil, now: Date = Date(), calendar: Calendar = .current,
                                 excludingWorkIDs: Set<UUID> = [], excludingAudioURLs: Set<URL> = []) async throws -> LibrarySmartResults {
        let url = databaseURL(for: folder)
        let query = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let db = try LibraryDatabase(url: url, readOnly: true)
            let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            if tokens.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return LibrarySmartResults() }
            let match = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
            var clauses: [String] = []
            var values: [String] = []
            if view.includesRecoveryWork {
                // Queued/Interrupted includes durable queued and recovery work;
                // Failed Jobs is the failed/uncertain subset of that work.
                if view == .failedJobs { clauses.append("failed = 1") }
                for token in tokens {
                    // Each word can match either work facts or the linked
                    // recording; a phrase may span both indexed documents.
                    clauses.append("(id IN (SELECT id FROM work_search WHERE work_search MATCH ?) OR audioPath IN (SELECT path FROM search WHERE search MATCH ?))")
                    let word = "\"\(token)\"*"
                    values += [word, word]
                }
                let excludedIDs = excludingWorkIDs.map { $0.uuidString.lowercased() }.sorted()
                if !excludedIDs.isEmpty {
                    clauses.append("lower(json_extract(payload, '$.recoveryID')) NOT IN (\(Self.placeholders(excludedIDs.count)))")
                    values += excludedIDs
                }
                let excludedPaths = Set(excludingAudioURLs.map { $0.standardizedFileURL.path }).sorted()
                if !excludedPaths.isEmpty {
                    clauses.append("(audioPath IS NULL OR audioPath NOT IN (\(Self.placeholders(excludedPaths.count))))")
                    values += excludedPaths
                }
                let rows = try db.rows("SELECT payload FROM work" + Self.condition(clauses) + " ORDER BY created ASC, id ASC", values)
                try Task.checkCancellation()
                return LibrarySmartResults(work: try rows.map { try JSONDecoder().decode(LibraryWorkItem.self, from: Data($0[0].utf8)) })
            }

            if !match.isEmpty {
                clauses.append("d.path IN (SELECT path FROM search WHERE search MATCH ?)")
                values.append(match)
            }
            if let status { clauses.append("d.status = ?"); values.append(status.rawValue) }
            let excludedPaths = Set(excludingAudioURLs.map { $0.standardizedFileURL.path }).sorted()
            if !excludedPaths.isEmpty {
                clauses.append("d.path NOT IN (\(Self.placeholders(excludedPaths.count)))")
                values += excludedPaths
            }
            var order = "d.created DESC, d.path ASC"
            switch view {
            case .unfinishedActions:
                clauses.append("d.unfinishedActions > 0")
            case .recentlyProcessed:
                clauses += ["d.processedAt >= ?", "d.processedAt <= ?"]
                values += [String(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970), String(now.timeIntervalSince1970)]
                order = "d.processedAt DESC, d.path ASC"
            case .peopleThisMonth:
                guard let month = calendar.dateInterval(of: .month, for: now) else { throw QueryFailure.invalidCalendarRange }
                clauses += ["d.created >= ?", "d.created < ?"]
                values += [String(month.start.timeIntervalSince1970), String(month.end.timeIntervalSince1970)]
                let rows = try db.rows("SELECT p.key, p.name, d.payload FROM people p JOIN documents d ON d.path = p.path"
                    + Self.condition(clauses) + " ORDER BY p.key ASC, " + order, values)
                var people: [LibraryPersonGroup] = []
                for row in rows {
                    try Task.checkCancellation()
                    let recording = try JSONDecoder().decode(RecordingBrowserItem.self, from: Data(row[2].utf8))
                    if people.last?.person.key == row[0] {
                        people[people.count - 1].recordings.append(recording)
                    } else {
                        people.append(.init(person: .init(key: row[0], name: row[1]), recordings: [recording]))
                    }
                }
                return LibrarySmartResults(people: people)
            default: break
            }
            let rows = try db.rows("SELECT d.payload FROM documents d" + Self.condition(clauses) + " ORDER BY " + order, values)
            try Task.checkCancellation()
            return LibrarySmartResults(recordings: try rows.map { try JSONDecoder().decode(RecordingBrowserItem.self, from: Data($0[0].utf8)) })
        }
        return try await withTaskCancellationHandler(operation: { try await query.value }, onCancel: { query.cancel() })
    }

    private enum QueryFailure: Error, LocalizedError {
        case invalidCalendarRange
        var errorDescription: String? { "The current calendar month could not be determined. Try refreshing the library." }
    }

    private nonisolated static func condition(_ clauses: [String]) -> String {
        clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
    }

    private nonisolated static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
