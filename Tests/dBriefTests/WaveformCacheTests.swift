import Foundation
import Testing
@testable import dBrief

@Suite @MainActor struct WaveformCacheTests {
    let url = URL(fileURLWithPath: "/tmp/a.m4a")
    let date = Date(timeIntervalSince1970: 1_000)

    @Test func storedSamplesAreReturnedForTheSameFileVersion() {
        let cache = WaveformCache(limit: 4)
        cache.store([0.1, 0.5], for: url, modificationDate: date)
        #expect(cache.samples(for: url, modificationDate: date) == [0.1, 0.5])
        #expect(cache.peek(url) == [0.1, 0.5])
    }

    @Test func aReplacedFileMisses() {
        let cache = WaveformCache(limit: 4)
        cache.store([0.1], for: url, modificationDate: date)
        #expect(cache.samples(for: url, modificationDate: date.addingTimeInterval(1)) == nil)
    }

    @Test func emptyResultsAreNotCached() {
        let cache = WaveformCache(limit: 4)
        cache.store([], for: url, modificationDate: date)
        #expect(cache.peek(url) == nil)
    }

    @Test func leastRecentlyUsedEntryIsEvicted() {
        let cache = WaveformCache(limit: 2)
        let a = URL(fileURLWithPath: "/tmp/a.m4a"), b = URL(fileURLWithPath: "/tmp/b.m4a"), c = URL(fileURLWithPath: "/tmp/c.m4a")
        cache.store([1], for: a, modificationDate: date)
        cache.store([2], for: b, modificationDate: date)
        _ = cache.samples(for: a, modificationDate: date) // a is now most recent
        cache.store([3], for: c, modificationDate: date)
        #expect(cache.peek(a) == [1])
        #expect(cache.peek(b) == nil)
        #expect(cache.peek(c) == [3])
    }

    @Test func modificationDateReadsTheFileSystem() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID()).m4a")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(WaveformCache.modificationDate(of: file) != nil)
        #expect(WaveformCache.modificationDate(of: URL(fileURLWithPath: "/nonexistent/x.m4a")) == nil)
    }
}
