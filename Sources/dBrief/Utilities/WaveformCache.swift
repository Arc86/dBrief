import Foundation

/// Recently drawn waveforms, so returning to a transcript (tab switch or
/// reselecting a recording) draws immediately instead of re-decoding the whole
/// file behind a flat baseline. ~3 KB per entry; least-recently-used eviction.
@MainActor
final class WaveformCache {
    static let shared = WaveformCache()

    private struct Entry {
        let modificationDate: Date?
        let samples: [Float]
    }

    private var entries: [URL: Entry] = [:]
    private var recency: [URL] = []
    private let limit: Int

    init(limit: Int = 32) {
        self.limit = limit
    }

    /// Last samples stored for `url`, without touching the file system — cheap
    /// enough to seed a view's first frame. `samples(for:modificationDate:)`
    /// validates against the file afterwards.
    func peek(_ url: URL) -> [Float]? {
        entries[url.standardizedFileURL]?.samples
    }

    /// Samples for a view's first frame, only when they match the file on disk —
    /// an in-place replacement must not paint the old waveform even briefly.
    func seed(for url: URL, modificationDate: Date?) -> [Float]? {
        guard let modificationDate,
              let entry = entries[url.standardizedFileURL],
              entry.modificationDate == modificationDate else { return nil }
        return entry.samples
    }

    func samples(for url: URL, modificationDate: Date?) -> [Float]? {
        let key = url.standardizedFileURL
        guard let entry = entries[key], entry.modificationDate == modificationDate else { return nil }
        touch(key)
        return entry.samples
    }

    func store(_ samples: [Float], for url: URL, modificationDate: Date?) {
        guard !samples.isEmpty else { return }
        let key = url.standardizedFileURL
        entries[key] = Entry(modificationDate: modificationDate, samples: samples)
        touch(key)
        while recency.count > limit {
            entries[recency.removeFirst()] = nil
        }
    }

    /// Uncached read (unlike `URL.resourceValues`), so a file replaced in place
    /// is detected.
    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func touch(_ key: URL) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
