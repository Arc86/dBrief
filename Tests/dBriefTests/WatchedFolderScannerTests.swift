import Foundation
import Testing
@testable import dBrief

@Suite("WatchedFolderScanner")
struct WatchedFolderScannerTests {

    // MARK: newlyStableFiles

    @Test("Processes a file that is stable across two scans and not yet processed")
    func stableNewFile() {
        let prev = [WatchedFileSnapshot(path: "/w/a.m4a", size: 100)]
        let curr = [WatchedFileSnapshot(path: "/w/a.m4a", size: 100)]
        let out = WatchedFolderScanner.newlyStableFiles(current: curr, previous: prev, processed: [])
        #expect(out.map(\.path) == ["/w/a.m4a"])
    }

    @Test("Skips a file growing between scans (still being written)")
    func skipsGrowingFile() {
        let prev = [WatchedFileSnapshot(path: "/w/a.m4a", size: 100)]
        let curr = [WatchedFileSnapshot(path: "/w/a.m4a", size: 250)]
        let out = WatchedFolderScanner.newlyStableFiles(current: curr, previous: prev, processed: [])
        #expect(out.isEmpty)
    }

    @Test("Skips a file seen for the first time (no previous snapshot)")
    func skipsBrandNewFile() {
        let curr = [WatchedFileSnapshot(path: "/w/a.m4a", size: 100)]
        let out = WatchedFolderScanner.newlyStableFiles(current: curr, previous: [], processed: [])
        #expect(out.isEmpty)
    }

    @Test("Skips files already processed")
    func skipsProcessed() {
        let prev = [WatchedFileSnapshot(path: "/w/a.m4a", size: 100)]
        let curr = [WatchedFileSnapshot(path: "/w/a.m4a", size: 100)]
        let out = WatchedFolderScanner.newlyStableFiles(
            current: curr, previous: prev, processed: ["/w/a.m4a"]
        )
        #expect(out.isEmpty)
    }

    @Test("Skips zero-byte files even when stable")
    func skipsEmptyFiles() {
        let prev = [WatchedFileSnapshot(path: "/w/a.m4a", size: 0)]
        let curr = [WatchedFileSnapshot(path: "/w/a.m4a", size: 0)]
        let out = WatchedFolderScanner.newlyStableFiles(current: curr, previous: prev, processed: [])
        #expect(out.isEmpty)
    }

    @Test("Processes only the stable, unseen file among several")
    func mixedBatch() {
        let prev = [
            WatchedFileSnapshot(path: "/w/stable.m4a", size: 100),
            WatchedFileSnapshot(path: "/w/growing.m4a", size: 50),
            WatchedFileSnapshot(path: "/w/done.m4a", size: 100),
        ]
        let curr = [
            WatchedFileSnapshot(path: "/w/stable.m4a", size: 100),   // stable, unseen → yes
            WatchedFileSnapshot(path: "/w/growing.m4a", size: 90),   // grew → no
            WatchedFileSnapshot(path: "/w/done.m4a", size: 100),     // stable but processed → no
            WatchedFileSnapshot(path: "/w/fresh.m4a", size: 100),    // no previous → no
        ]
        let out = WatchedFolderScanner.newlyStableFiles(
            current: curr, previous: prev, processed: ["/w/done.m4a"]
        )
        #expect(out.map(\.path) == ["/w/stable.m4a"])
    }

    // MARK: audioFiles (filesystem)

    @Test("Enumerates audio files non-recursively and ignores non-audio + subfolders")
    func enumeratesAudioOnly() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wf-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try Data("a".utf8).write(to: dir.appendingPathComponent("meeting.m4a"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("c".utf8).write(to: dir.appendingPathComponent("voice.WAV")) // case-insensitive ext
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("d".utf8).write(to: sub.appendingPathComponent("nested.m4a"))

        let found = Set(WatchedFolderScanner.audioFiles(in: dir).map { ($0.path as NSString).lastPathComponent })
        #expect(found == ["meeting.m4a", "voice.WAV"])
    }
}
