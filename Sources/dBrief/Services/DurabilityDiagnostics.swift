import Foundation
import OSLog

struct DurabilityDiagnosticFailure: Codable, Equatable, Sendable {
    let domain: String
    let code: Int

    init(error: Error) {
        let value = error as NSError
        self.domain = value.domain
        self.code = value.code
    }
}

struct DurabilityEvent: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case started
        case succeeded
        case warning
        case failed
    }

    let id: UUID
    let timestamp: Date
    let sessionID: UUID?
    let name: String
    let outcome: Outcome
    let measurements: [String: Int64]
    let failure: DurabilityDiagnosticFailure?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: UUID? = nil,
        name: String,
        outcome: Outcome,
        measurements: [String: Int64] = [:],
        failure: DurabilityDiagnosticFailure? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.name = name
        self.outcome = outcome
        self.measurements = measurements
        self.failure = failure
    }
}

/// Small, privacy-safe JSON-lines journal that survives app restarts. Events use
/// fixed names, aggregate measurements, and error domain/code fingerprints only;
/// meeting titles, file paths, transcript text, participant names, and credentials
/// are never accepted by this API.
final class DurabilityJournal: @unchecked Sendable {
    static let shared = DurabilityJournal()

    private let lock = NSLock()
    private let fileManager: FileManager
    private let directoryURL: URL
    private let maxBytes: Int
    private let retainedEventCount: Int

    init(
        directoryURL: URL = AppSupportPaths.subdirectory("Diagnostics"),
        fileManager: FileManager = .default,
        maxBytes: Int = 512 * 1024,
        retainedEventCount: Int = 400
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maxBytes = maxBytes
        self.retainedEventCount = retainedEventCount
    }

    var journalURL: URL { directoryURL.appendingPathComponent("durability-events.jsonl") }

    func record(_ event: DurabilityEvent) {
        lock.withLock {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                var line = try encoder.encode(event)
                line.append(0x0A)

                if !fileManager.fileExists(atPath: journalURL.path) {
                    try line.write(to: journalURL, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: journalURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                    try handle.close()
                }
                try rotateIfNeeded()
            } catch {
                Logger.recording.error(
                    "Durability journal write failed: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)"
                )
            }
        }
    }

    func recentEvents(limit: Int = 250) -> [DurabilityEvent] {
        lock.withLock { loadEvents().suffix(max(0, limit)).map { $0 } }
    }

    private func loadEvents() -> [DurabilityEvent] {
        guard let data = try? Data(contentsOf: journalURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(DurabilityEvent.self, from: Data(line.utf8))
        }
    }

    private func rotateIfNeeded() throws {
        let attributes = try fileManager.attributesOfItem(atPath: journalURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size > maxBytes
        else { return }
        let retained = loadEvents().suffix(retainedEventCount)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()
        for event in retained {
            output.append(try encoder.encode(event))
            output.append(0x0A)
        }
        try output.write(to: journalURL, options: .atomic)
    }
}

struct DBriefDiagnosticsReport: Codable, Sendable {
    struct AppInfo: Codable, Sendable {
        let version: String
        let build: String
        let bundleIdentifier: String
        let channel: String
        let operatingSystem: String
        let architecture: String
    }

    struct StorageInfo: Codable, Sendable {
        let recordingFolderExists: Bool
        let recordingFolderWritable: Bool
        let availableCapacityBytes: Int64?
    }

    struct RecoverySessionInfo: Codable, Sendable {
        let sessionID: UUID
        let startedAt: Date
        let state: InterruptedSessionManifest.State
        let existingTrackCount: Int
        let existingTrackBytes: Int64
    }

    let formatVersion: Int
    let generatedAt: Date
    let app: AppInfo
    let storage: StorageInfo
    let recoverySessions: [RecoverySessionInfo]
    let recentDurabilityEvents: [DurabilityEvent]
    let privacyNote: String
}

enum DBriefDiagnosticsExporter {
    static func makeReport(
        recordingFolderURL: URL,
        journal: DurabilityJournal = .shared,
        recoveryRootURL: URL = InterruptedSessionStore.defaultRootURL,
        fileManager: FileManager = .default
    ) -> DBriefDiagnosticsReport {
        var isDirectory: ObjCBool = false
        let folderExists = fileManager.fileExists(
            atPath: recordingFolderURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        let availableCapacity = try? recordingFolderURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage

        let recovery = InterruptedSessionDiscovery.discover(
            in: recoveryRootURL,
            fileManager: fileManager
        ).map { candidate in
            let bytes = candidate.existingTrackURLs.reduce(Int64(0)) { total, url in
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            return DBriefDiagnosticsReport.RecoverySessionInfo(
                sessionID: candidate.manifest.id,
                startedAt: candidate.manifest.startedAt,
                state: candidate.manifest.state,
                existingTrackCount: candidate.existingTracks.count,
                existingTrackBytes: bytes
            )
        }

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif

        let bundleID = AppSupportPaths.bundleIdentifier
        return DBriefDiagnosticsReport(
            formatVersion: 1,
            generatedAt: Date(),
            app: .init(
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                bundleIdentifier: bundleID,
                channel: bundleID.hasSuffix(".beta") ? "beta" : "stable",
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architecture
            ),
            storage: .init(
                recordingFolderExists: folderExists,
                recordingFolderWritable: folderExists && fileManager.isWritableFile(atPath: recordingFolderURL.path),
                availableCapacityBytes: availableCapacity
            ),
            recoverySessions: recovery,
            recentDurabilityEvents: journal.recentEvents(),
            privacyNote: "This report excludes audio, transcripts, meeting titles, participant names, file paths, and credentials."
        )
    }

    static func writeReport(_ report: DBriefDiagnosticsReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
