import Foundation
import Testing
@testable import dBrief

@Suite("Restartable Markdown export")
struct MarkdownOutputStoreTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func collisionsChooseSeparateDestinationAndPreserveExistingNote() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("same-title.md")
        try "User note".write(to: url, atomically: true, encoding: .utf8)
        let store = MarkdownOutputStore()
        let proposed = MarkdownExportPlan(destination: url, content: "New meeting", generatedTitle: nil)
        let plan = try await store.prepare(proposed, jobID: UUID())
        #expect(plan.destination != url)
        _ = try await store.publish(plan)
        #expect(try String(contentsOf: url, encoding: .utf8) == "User note")
        #expect(try String(contentsOf: plan.destination, encoding: .utf8) == "New meeting")
    }

    @Test
    func conflictAfterPlanWasSavedNeverOverwritesOrChoosesAnotherPath() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        let plan = MarkdownExportPlan(destination: url, content: "Generated", generatedTitle: nil)
        try "User edits".write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: MarkdownOutputStore.OutputError.self) {
            _ = try await MarkdownOutputStore().publish(plan)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "User edits")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["note.md"])
    }

    @Test
    func checkpointedNotePreservesEditsAndMissingNoteFails() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        let plan = MarkdownExportPlan(destination: url, content: "Generated", generatedTitle: nil)
        let store = MarkdownOutputStore()
        _ = try await store.publish(plan)
        try "Edited later".write(to: url, atomically: true, encoding: .utf8)
        _ = try await store.publish(plan, alreadyCompleted: true)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Edited later")
        try FileManager.default.removeItem(at: url)
        await #expect(throws: (any Error).self) {
            _ = try await store.publish(plan, alreadyCompleted: true)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func legacyNoteIsAdoptedWithoutChangingItsContent() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("legacy.md")
        try "Original with user edits".write(to: url, atomically: true, encoding: .utf8)
        let store = MarkdownOutputStore()
        let plan = try await store.adoptExisting(at: url, generatedTitle: "Legacy")
        _ = try await store.publish(plan)
        #expect(plan.content == "Original with user edits")
        #expect(plan.generatedTitle == "Legacy")
    }

    @Test
    func futurePlanAndSymbolicLinksFailWithoutChangingFiles() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        var plan = MarkdownExportPlan(destination: url, content: "Generated", generatedTitle: nil)
        plan.version = 99
        let store = MarkdownOutputStore()
        await #expect(throws: MarkdownOutputStore.OutputError.self) {
            _ = try await store.publish(plan)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        plan.version = MarkdownExportPlan.currentVersion
        let target = folder.appendingPathComponent("target.md")
        try "Private note".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        await #expect(throws: MarkdownOutputStore.OutputError.self) {
            _ = try await store.publish(plan)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "Private note")
    }
}
