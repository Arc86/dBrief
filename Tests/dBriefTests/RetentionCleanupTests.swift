import Foundation
import Testing
@testable import dBrief

struct RetentionCleanupTests {
    // MARK: - Classification

    @Test
    func classifiesRecordingArtifacts() {
        let base = URL(fileURLWithPath: "/tmp/2024-01-01_0900_meeting")
        #expect(RetentionCleanup.isRecordingFile(base.appendingPathExtension("m4a")))
        #expect(RetentionCleanup.isRecordingFile(base.appendingPathExtension("wav")))
        // Recording metadata + resume-queue sidecars travel with the audio.
        #expect(RetentionCleanup.isRecordingFile(base.appendingPathExtension("json")))
        #expect(RetentionCleanup.isRecordingFile(base.appendingPathExtension("queue.json")))
    }

    @Test
    func classifiesTranscriptArtifacts() {
        let base = URL(fileURLWithPath: "/tmp/2024-01-01_0900_meeting")
        #expect(RetentionCleanup.isTranscriptFile(base.appendingPathExtension("md").lastPathComponent))
        #expect(RetentionCleanup.isTranscriptFile(base.appendingPathExtension("transcript.json").lastPathComponent))
        #expect(RetentionCleanup.isTranscriptFile(base.appendingPathExtension("richtranscript.json").lastPathComponent))
        #expect(RetentionCleanup.isTranscriptFile(base.appendingPathExtension("insights.json").lastPathComponent))
        #expect(RetentionCleanup.isTranscriptFile(base.appendingPathExtension("chat.json").lastPathComponent))
    }

    @Test
    func transcriptSidecarsAreNotTreatedAsRecordings() {
        // The compound `.richtranscript.json` / `.insights.json` names also end in
        // `.json`, but must not be swept by the recordings policy.
        let base = URL(fileURLWithPath: "/tmp/meeting")
        #expect(!RetentionCleanup.isRecordingFile(base.appendingPathExtension("richtranscript.json")))
        #expect(!RetentionCleanup.isRecordingFile(base.appendingPathExtension("insights.json")))
        #expect(!RetentionCleanup.isRecordingFile(base.appendingPathExtension("transcript.json")))
        #expect(!RetentionCleanup.isRecordingFile(base.appendingPathExtension("chat.json")))
    }

    // MARK: - Sweeps

    @Test
    func recordingsSweepDeletesAudioAndMetadataButKeepsTranscripts() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let base = folder.appendingPathComponent("2024-01-01_0900_meeting")
        let audio = base.appendingPathExtension("m4a")
        let segment = folder.appendingPathComponent("2024-01-01_0900_meeting_part01.m4a")
        let metadata = base.appendingPathExtension("json")
        let markdown = base.appendingPathExtension("md")
        let rich = base.appendingPathExtension("richtranscript.json")
        for url in [audio, segment, metadata, markdown, rich] {
            try Data(count: 16).write(to: url)
        }

        // Push "now" past the cutoff so the just-created files count as old.
        let future = Date().addingTimeInterval(10 * 86_400)
        let result = RetentionCleanup.cleanup(
            category: .recordings,
            olderThanDays: 7,
            in: [folder],
            now: future
        )

        #expect(result.filesDeleted == 3) // audio + segment + metadata
        #expect(!fm.fileExists(atPath: audio.path))
        #expect(!fm.fileExists(atPath: segment.path))
        #expect(!fm.fileExists(atPath: metadata.path))
        // Transcript artifacts are left alone by the recordings policy.
        #expect(fm.fileExists(atPath: markdown.path))
        #expect(fm.fileExists(atPath: rich.path))
    }

    @Test
    func transcriptsSweepDeletesNotesButKeepsAudio() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let base = folder.appendingPathComponent("2024-01-01_0900_meeting")
        let audio = base.appendingPathExtension("m4a")
        let metadata = base.appendingPathExtension("json")
        let markdown = base.appendingPathExtension("md")
        let rich = base.appendingPathExtension("richtranscript.json")
        let insights = base.appendingPathExtension("insights.json")
        for url in [audio, metadata, markdown, rich, insights] {
            try Data(count: 16).write(to: url)
        }

        let future = Date().addingTimeInterval(10 * 86_400)
        let result = RetentionCleanup.cleanup(
            category: .transcripts,
            olderThanDays: 7,
            in: [folder],
            now: future
        )

        #expect(result.filesDeleted == 3) // md + richtranscript + insights
        #expect(!fm.fileExists(atPath: markdown.path))
        #expect(!fm.fileExists(atPath: rich.path))
        #expect(!fm.fileExists(atPath: insights.path))
        // Audio and its plain metadata sidecar are kept.
        #expect(fm.fileExists(atPath: audio.path))
        #expect(fm.fileExists(atPath: metadata.path))
    }

    @Test
    func recentFilesAreKept() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let audio = folder.appendingPathComponent("recent.m4a")
        try Data(count: 16).write(to: audio)

        // Real "now": the file was just created, so it's newer than a 7-day cutoff.
        let result = RetentionCleanup.cleanup(category: .recordings, olderThanDays: 7, in: [folder])

        #expect(result.filesDeleted == 0)
        #expect(fm.fileExists(atPath: audio.path))
    }

    @Test
    func deduplicatesFoldersAndSkipsMissing() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let audio = folder.appendingPathComponent("old.m4a")
        try Data(count: 16).write(to: audio)
        let missing = fm.temporaryDirectory.appendingPathComponent("retention-missing-\(UUID().uuidString)", isDirectory: true)

        let future = Date().addingTimeInterval(10 * 86_400)
        // The same folder twice + a non-existent folder: the file is deleted once,
        // and the missing folder is skipped without error.
        let result = RetentionCleanup.cleanup(
            category: .recordings,
            olderThanDays: 1,
            in: [folder, folder, missing],
            now: future
        )

        #expect(result.filesDeleted == 1)
    }
}
