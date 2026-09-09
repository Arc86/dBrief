import Foundation

extension LibraryIndex {
    private enum SourceKind { case job, delivery, capture, queue, schedule }

    /// Recovery journals are global: unfinalized work may have no destination
    /// folder at all. The UI must label recovery views as including all folders.
    struct WorkSnapshot {
        let sources: [String: LibraryWorkSource]
        let audioEntries: [RecordingFileEntry]
    }

    nonisolated func refreshWorkSources(db: LibraryDatabase, folder: URL, entries: [RecordingFileEntry],
                                       configuredQueueFolders: [URL], rebuild: Bool,
                                       reads: inout Int) throws -> WorkSnapshot {
        let rows = try db.rows("SELECT path, fingerprint, payload FROM work_sources")
        let old = Dictionary(uniqueKeysWithValues: rows.map { ($0[0], ($0[1], $0[2])) })
        var sources: [String: LibraryWorkSource] = [:]
        func load(_ rawURL: URL, kind: SourceKind) throws -> LibraryWorkSource? {
            let url = rawURL.standardizedFileURL
            if let loaded = sources[url.path] { return loaded }
            try Task.checkCancellation()
            let fingerprint = try fileFingerprint(url)
            guard fingerprint != "missing" else { return nil }
            let source: LibraryWorkSource
            if !rebuild, let cached = old[url.path], cached.0 == fingerprint {
                source = try JSONDecoder().decode(LibraryWorkSource.self, from: Data(cached.1.utf8))
            } else {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidWork }
                reads += 1
                let data = try read(url)
                do { source = try decodeSource(data, at: url, kind: kind) }
                catch { throw Failure.invalidWork }
                guard try fileFingerprint(url) == fingerprint else { throw Failure.sourceChanged }
                let payload = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
                try db.rows("INSERT OR REPLACE INTO work_sources VALUES (?, ?, ?)", [url.path, fingerprint, payload])
            }
            sources[url.path] = source
            return source
        }
        // Absence is normal before the queue has ever been used. Validate its
        // storage directory as well so an offline root is not treated as empty.
        _ = try children(of: queueScheduleURL.deletingLastPathComponent())
        let schedule: QueueSchedule
        if case .schedule(let saved) = try load(queueScheduleURL, kind: .schedule) { schedule = saved }
        else { schedule = QueueSchedule() }
        let folders = schedule.discoveryFolders(configured: [folder] + configuredQueueFolders)
        var audioEntries = entries
        for queueFolder in folders {
            if try canSkipUnusedFolder(queueFolder, currentFolder: folder, schedule: schedule, cachedPaths: Array(old.keys)) { continue }
            if queueFolder.standardizedFileURL != folder.standardizedFileURL {
                audioEntries += try discover(in: queueFolder)
            }
            var failed = false
            guard let enumerator = FileManager.default.enumerator(at: queueFolder, includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles, errorHandler: { _, _ in failed = true; return false }) else { throw Failure.unavailableFolder }
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".queue.json") {
                _ = try load(url, kind: .queue)
            }
            if failed { throw Failure.unavailableFolder }
        }
        for child in try children(of: jobsRoot).sorted(by: { $0.path < $1.path }) where UUID(uuidString: child.lastPathComponent) != nil {
            _ = try load(child.appendingPathComponent(ProcessingJobStore.manifestFileName), kind: .job)
        }
        for child in try children(of: deliveriesRoot).sorted(by: { $0.path < $1.path }) where child.pathExtension == "json" {
            _ = try load(child, kind: .delivery)
        }
        for child in try children(of: sessionsRoot).sorted(by: { $0.path < $1.path }) {
            guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            _ = try load(child.appendingPathComponent(InterruptedSessionManifest.fileName), kind: .capture)
        }
        for path in old.keys where sources[path] == nil {
            try db.rows("DELETE FROM work_sources WHERE path = ?", [path])
        }
        return WorkSnapshot(sources: sources, audioEntries: audioEntries)
    }

    private nonisolated func canSkipUnusedFolder(_ folder: URL, currentFolder: URL,
                                                schedule: QueueSchedule, cachedPaths: [String]) throws -> Bool {
        guard try fileFingerprint(folder) == "missing" else { return false }
        func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let path = resolved(folder)
        guard path != resolved(currentFolder),
              !schedule.discoveryFolders(configured: []).contains(where: { resolved($0) == path }),
              !cachedPaths.contains(where: { $0.hasSuffix(".queue.json") && resolved(URL(fileURLWithPath: $0)).hasPrefix(path + "/") }) else {
            throw Failure.unavailableFolder
        }
        // An unused local destination may not have been created yet. Require a
        // readable ancestor, and never mistake an unmounted volume for that case.
        var ancestor = folder.deletingLastPathComponent()
        while try fileFingerprint(ancestor) == "missing" {
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { throw Failure.unavailableFolder }
            ancestor = parent
        }
        guard ancestor.standardizedFileURL.path != "/Volumes" else { throw Failure.unavailableFolder }
        _ = try FileManager.default.contentsOfDirectory(at: ancestor, includingPropertiesForKeys: nil)
        return true
    }

    private nonisolated func children(of root: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            // Missing storage is normal on first use; an inaccessible parent
            // volume is not evidence that all its recovery work was deleted.
            _ = try FileManager.default.contentsOfDirectory(at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            return []
        }
    }

    private nonisolated func decodeSource(_ data: Data, at url: URL, kind: SourceKind) throws -> LibraryWorkSource {
        let decoder = JSONDecoder()
        switch kind {
        case .job:
            let job = try decoder.decode(PersistedProcessingJob.self, from: data)
            guard job.version == PersistedProcessingJob.currentVersion,
                  job.checkpoint.version == ProcessingCheckpoint.currentVersion,
                  job.checkpoint.jobID == job.id,
                  UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) == job.id else { throw Failure.invalidWork }
            try job.markdownExport?.validate()
            return .job(.init(job))
        case .delivery:
            let batch = try decoder.decode(IntegrationDeliveryBatch.self, from: data)
            try batch.validate()
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == batch.id else { throw Failure.invalidWork }
            return .delivery(.init(batch))
        case .capture:
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(InterruptedSessionManifest.self, from: data)
            guard manifest.version == InterruptedSessionManifest.currentVersion,
                  UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) == manifest.id else { throw Failure.invalidWork }
            return .capture(manifest)
        case .queue:
            return .queue(try QueueItem.decode(data, from: url).id)
        case .schedule:
            let schedule = try decoder.decode(QueueSchedule.self, from: data)
            guard schedule.version == 1, (schedule.knownFolders ?? []).allSatisfy({ $0.hasPrefix("/") }) else { throw Failure.invalidWork }
            return .schedule(schedule)
        }
    }

    nonisolated func latestJobs(_ sources: [String: LibraryWorkSource]) -> [String: LibraryJobSummary] {
        var latest: [String: LibraryJobSummary] = [:]
        for (_, source) in sources.sorted(by: { $0.key < $1.key }) {
            guard case .job(let job) = source, let summary = LibraryJobSummary(job) else { continue }
            if latest[summary.audioPath].map({ $0.updatedAt < summary.updatedAt }) ?? true {
                latest[summary.audioPath] = summary
            }
        }
        return latest
    }

    nonisolated func refreshWorkItems(db: LibraryDatabase, sources: [String: LibraryWorkSource],
                                     entries: [RecordingFileEntry]) throws {
        let jobs = sources.values.compactMap { if case .job(let job) = $0 { job } else { nil } }
        let deliveries = sources.values.compactMap { if case .delivery(let batch) = $0 { batch } else { nil } }
        let queuedIDs = Set(sources.values.compactMap { if case .queue(let id) = $0 { id } else { nil } })
        let recovered = RecoveryQueueEntry.entries(jobFacts: jobs, deliveryFacts: deliveries, queuedIDs: [], activeID: nil)
        let recoveryItems = recovered.map { entry in
            let job = jobs.first { $0.id == entry.id }
            let delivery = deliveries.first { $0.id == entry.id && !$0.isComplete && $0.dismissedFromQueue != true }
            return LibraryWorkItem(id: "recovery:" + entry.id.uuidString.lowercased(), recoveryID: entry.id,
                target: entry.isDelivery ? .delivery : .recovery, title: entry.title, audioURL: entry.audioURL, date: entry.date, status: entry.status,
                failed: delivery?.hasFailure == true || (job?.status == .failed && job?.dismissedFromQueue != true), sourcePath: nil, associatedApp: job?.associatedApp ?? "")
        }
        var items = recoveryItems.filter { !queuedIDs.contains($0.recoveryID) }
        let documents = try db.rows("SELECT path, payload FROM documents")
        let recordings = try Dictionary(uniqueKeysWithValues: documents.map {
            ($0[0], try JSONDecoder().decode(RecordingBrowserItem.self, from: Data($0[1].utf8)))
        })
        let audioByBase = Dictionary(entries.map { ($0.url.standardizedFileURL.deletingPathExtension().path, $0.url.standardizedFileURL) }, uniquingKeysWith: { a, b in
            a.path < b.path ? a : b
        })
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            switch source {
            case .queue(let id):
                let marker = URL(fileURLWithPath: path)
                let base = marker.deletingPathExtension().deletingPathExtension()
                let audio = audioByBase[base.path]
                let recording = audio.flatMap { recordings[$0.path] }
                let date = try marker.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
                let recovery = recoveryItems.first { $0.recoveryID == id }
                let failedRecovery = recovery.flatMap { $0.failed ? $0 : nil }
                items.append(.init(id: "queue:" + path, recoveryID: id, target: failedRecovery?.target ?? .queue,
                    title: recording?.title ?? base.lastPathComponent, audioURL: audio, date: recording?.date ?? date,
                    status: failedRecovery?.status ?? (audio == nil ? "Queued recording unavailable" : "Queued"),
                    failed: recovery?.failed == true || audio == nil,
                    sourcePath: path, associatedApp: ""))
            case .capture(let manifest):
                guard manifest.state.isRecoverable, !jobs.contains(where: {
                    $0.recordingID == manifest.id || $0.recoveryManifestPath.map {
                        URL(fileURLWithPath: $0).standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
                    } == true
                }) else { continue }
                let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
                var available = false
                for track in manifest.tracks {
                    guard !track.relativePath.isEmpty, !track.relativePath.hasPrefix("/"),
                          !track.relativePath.split(separator: "/").contains("..") else { throw Failure.invalidWork }
                    let trackURL = directory.appendingPathComponent(track.relativePath).resolvingSymlinksInPath().standardizedFileURL
                    if try fileFingerprint(trackURL) != "missing" {
                        // Foundation normalizes existing /private/var paths to
                        // /var but may leave absent tracks under /private/var.
                        // Compare resolved containment only for existing tracks.
                        guard trackURL.path.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw Failure.invalidWork }
                        guard try trackURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.invalidWork }
                        available = true
                    }
                }
                items.append(.init(id: "capture:" + manifest.id.uuidString.lowercased(), recoveryID: manifest.id,
                    target: .capture, title: "Interrupted recording", audioURL: nil, date: manifest.startedAt,
                    status: available ? "Interrupted capture" : "Recording unavailable", failed: !available,
                    sourcePath: path, associatedApp: ""))
            default: break
            }
        }
        let old = try Dictionary(uniqueKeysWithValues: db.rows("SELECT id, payload FROM work").map { ($0[0], $0[1]) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for item in items {
            let payload = String(decoding: try encoder.encode(item), as: UTF8.self)
            guard old[item.id] != payload else { continue }
            try db.rows("DELETE FROM work_search WHERE id = ?", [item.id])
            try db.rows("INSERT OR REPLACE INTO work VALUES (?, ?, ?, NULLIF(?, ''), ?, ?)",
                [item.id, payload, item.title, item.audioURL?.path ?? "", item.failed ? "1" : "0", String(item.date.timeIntervalSince1970)])
            try db.rows("INSERT INTO work_search(id, body) VALUES (?, ?)",
                [item.id, [item.title, item.status, item.associatedApp, item.audioURL?.lastPathComponent ?? ""].joined(separator: "\n")])
        }
        let seen = Set(items.map(\.id))
        for id in old.keys where !seen.contains(id) {
            try db.rows("DELETE FROM work_search WHERE id = ?", [id])
            try db.rows("DELETE FROM work WHERE id = ?", [id])
        }
    }
}
