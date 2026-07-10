import Foundation
import OSLog

/// Append-only log of `ModelPerformanceRecord`s, persisted as a single JSON
/// array in Application Support. Mirrors the actor + atomic-write pattern of the
/// other stores. Unlike the per-recording sidecars this is an app-level log: the
/// Model Performance panel aggregates across every recording.
actor ModelPerformanceStore {
    private let fileManager = FileManager.default
    private let url: URL

    /// Keep the log bounded — older sessions are dropped once the cap is hit so
    /// the file can't grow without limit over the app's lifetime.
    private let maxRecords = 5_000

    /// In-memory copy of the log, loaded from disk once. This actor is the sole
    /// writer, so the cache stays authoritative — `append` no longer re-decodes
    /// the whole file (up to `maxRecords`) on every recording.
    private var cache: [ModelPerformanceRecord]?

    init(url: URL = ModelPerformanceStore.defaultURL()) {
        self.url = url
    }

    private func loadedRecords() -> [ModelPerformanceRecord] {
        if let cache { return cache }
        let loaded = readFromDisk()
        cache = loaded
        return loaded
    }

    /// `~/Library/Application Support/<bundle id>/model-performance.json`,
    /// alongside the `LocalAIPlugin` model cache.
    static func defaultURL() -> URL {
        AppSupportPaths.base.appendingPathComponent("model-performance.json")
    }

    /// Load all recorded sessions. Returns an empty array when the log is absent
    /// or unreadable (a corrupt log shouldn't break the panel).
    func load() -> [ModelPerformanceRecord] {
        loadedRecords()
    }

    /// Average end-to-end transcription realtime ratio (audio-seconds transcribed
    /// per wall-second) for a given model, used to estimate a live ETA. Averages
    /// `audioDuration / transcriptionTime` over every record for that model that
    /// carries both timings; returns `nil` when there's no usable history, so the
    /// caller falls back to an indeterminate spinner rather than a fake bar.
    func averageTranscriptionRealtime(forModel model: String) -> Double? {
        let ratios = loadedRecords().compactMap { record -> Double? in
            guard record.transcriptionModel == model,
                  let audio = record.audioDuration, audio > 0,
                  let wall = record.transcriptionTime, wall > 0
            else { return nil }
            return audio / wall
        }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Double(ratios.count)
    }

    /// Append a session and persist. Best-effort: failures are logged, not thrown.
    func append(_ record: ModelPerformanceRecord) {
        var records = loadedRecords()
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        cache = records
        save(records)
    }

    /// Remove all recorded sessions (the "Clear stats" action). Does NOT touch
    /// the lifetime transcribed-minutes odometer, which lives in `AppSettings`.
    func clear() {
        cache = []
        try? fileManager.removeItem(at: url)
    }

    private func readFromDisk() -> [ModelPerformanceRecord] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ModelPerformanceRecord].self, from: data)
        } catch {
            Logger.app.error("ModelPerformanceStore: failed to load: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func save(_ records: [ModelPerformanceRecord]) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.app.error("ModelPerformanceStore: failed to save: \(error.localizedDescription, privacy: .public)")
        }
    }
}
