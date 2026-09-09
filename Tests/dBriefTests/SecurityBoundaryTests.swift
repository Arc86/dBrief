import Foundation
import Testing
@testable import dBrief

struct SecurityBoundaryTests {
    @Test func videoURLRejectsCommandOptionBeforeLaunchingHelper() async {
        do {
            _ = try await YouTubeDownloadService().downloadAudio(from: "--version")
            Issue.record("Expected invalidURL")
        } catch YouTubeDownloadError.invalidURL { }
        catch { Issue.record("Expected invalidURL, got \(error)") }
    }
    @Test func retentionPreservesUnrelatedFilesInSubfolders() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("dbrief-security-audit-\(UUID())")
        let nested = folder.appendingPathComponent("unrelated-project")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let note = nested.appendingPathComponent("personal-notes.md")
        let config = nested.appendingPathComponent("package.json")
        let audio = nested.appendingPathComponent("personal-audio.m4a")
        try Data("unrelated audio".utf8).write(to: audio)
        try Data("SYNTHETIC NON-DBRIEF NOTE".utf8).write(to: note)
        try Data("{}".utf8).write(to: config)
        let future = Date().addingTimeInterval(10 * 86_400)
        let transcripts = RetentionCleanup.cleanup(category: .transcripts, olderThanDays: 7, in: [folder], now: future)
        let recordings = RetentionCleanup.cleanup(category: .recordings, olderThanDays: 7, in: [folder], now: future)
        #expect(transcripts.filesDeleted == 0)
        #expect(recordings.filesDeleted == 0)
        #expect(fm.fileExists(atPath: note.path))
        #expect(fm.fileExists(atPath: config.path))
        #expect(fm.fileExists(atPath: audio.path))
    }

    @Test func cleanupKeepsOwnershipUntilLaterTranscriptSweep() throws {
        let f = try RetentionFixture(); defer { f.clean() }
        let audio = f.root.appendingPathComponent("meeting.m4a")
        let transcript = f.root.appendingPathComponent("meeting.transcript.json")
        let note = f.root.appendingPathComponent("notes/Meeting.md")
        try f.own(audio, markdown: note)
        try Data("audio".utf8).write(to: audio)
        try Data("transcript".utf8).write(to: transcript)
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("generated note".utf8).write(to: note)
        _ = RetentionCleanup.cleanup(category: .recordings, olderThanDays: 7, in: [f.root], now: f.future)
        #expect(!f.exists(audio))
        #expect(f.exists(audio.deletingPathExtension().appendingPathExtension("json")))
        #expect(f.exists(transcript) && f.exists(note))
        _ = RetentionCleanup.cleanup(category: .transcripts, olderThanDays: 7, in: [f.root], now: f.future)
        #expect(!f.exists(transcript) && !f.exists(note))
    }

    @Test(arguments: [true, false])
    func queuedRecordingProtectsDifferentlyNamedExport(useQueueMarker: Bool) throws {
        let f = try RetentionFixture(); defer { f.clean() }
        let audio = f.root.appendingPathComponent("capture.m4a")
        let note = f.root.appendingPathComponent("notes/Weekly review.md")
        try f.own(audio, markdown: note)
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("generated note".utf8).write(to: note)
        if useQueueMarker {
            try Data("{}".utf8).write(to: f.root.appendingPathComponent("capture.queue.json"))
        }
        let protected: Set<String> = useQueueMarker ? [] : [audio.deletingPathExtension().resolvingSymlinksInPath().path]
        let result = RetentionCleanup.cleanup(category: .transcripts, olderThanDays: 7, in: [f.root],
                                              now: f.future, protectedBases: protected)
        #expect(result.filesDeleted == 0)
        #expect(f.exists(note))
    }

    @Test func cleanupPreservesOutOfScopeLinkedNotesAndSymlinks() throws {
        let f = try RetentionFixture(); defer { f.clean() }
        let library = f.root.appendingPathComponent("library")
        let outside = f.root.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("private note".utf8).write(to: outside)
        let audio = library.appendingPathComponent("meeting.m4a")
        try f.own(audio, markdown: outside)
        let link = library.appendingPathComponent("meeting.transcript.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        _ = RetentionCleanup.cleanup(category: .transcripts, olderThanDays: 7, in: [library], now: f.future)
        #expect(f.exists(outside) && f.exists(link))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "private note")
    }
    @Test(arguments: ["--update-to=example/repo", "relative/path", "file:///tmp/audio", "https:///missing", "ftp://example.com/file", "https://user:password@example.com/video"])
    func unsafeVideoInputsAreRejected(_ input: String) {
        #expect(throws: YouTubeDownloadError.self) { try YouTubeDownloadService.validatedVideoURL(input) }
    }

    @Test func validVideoURLsRemainSingleOperands() throws {
        let url = "https://example.com/video?q=--exec&title=hello%20world"
        let value = try YouTubeDownloadService.validatedVideoURL("  " + url + "\n")
        #expect(YouTubeDownloadService.urlOperand(value) == ["--", url])
    }

    @Test func redirectPolicyRequiresSameSchemeHostAndEffectivePort() {
        let origin = URL(string: "https://example.com/start")!
        #expect(SensitiveRedirectPolicy.allows(from: origin, to: URL(string: "https://EXAMPLE.com:443/next")))
        for target in ["http://example.com/next", "https://example.com:444/next", "https://other.example/next", "file:///tmp/next", "https://user:pass@example.com/next"] {
            #expect(!SensitiveRedirectPolicy.allows(from: origin, to: URL(string: target)))
        }
    }
}

private struct RetentionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-ownership-\(UUID())")
    let future = Date().addingTimeInterval(30 * 86_400)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func own(_ audio: URL, markdown: URL? = nil, segments: [String] = []) throws {
        let metadata = RecordingMetadataPayload(recordingID: UUID(), dateISO8601: "2026-01-01T00:00:00Z", durationSeconds: 1,
            meetingTitle: "Meeting", masterFileName: audio.lastPathComponent, segmentFileNames: segments, warnings: [])
        try JSONEncoder().encode(metadata).write(to: audio.deletingPathExtension().appendingPathExtension("json"))
        if let markdown {
            let insights = RecordingInsights(summary: "", actionItems: [], tags: [], sentiment: "neutral", markdownPath: markdown.path)
            try JSONEncoder().encode(insights).write(to: audio.deletingPathExtension().appendingPathExtension("insights.json"))
        }
    }
}
