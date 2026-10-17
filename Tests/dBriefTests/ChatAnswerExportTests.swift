import Foundation
import Testing
@testable import dBrief

@Suite("Assistant answer export")
struct ChatAnswerExportTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-answer-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func exportsOnlyTheCompletedAssistantAnswer() {
        let message = ChatMessage(
            role: .assistant,
            content: "<think>Private reasoning</think>\n## Résumé\n- **Ship** café notes in 東京 🚀"
        )

        #expect(ChatAnswerExport.payload(for: message, format: .markdown)
                == "## Résumé\n- **Ship** café notes in 東京 🚀")
        #expect(ChatAnswerExport.payload(for: message, format: .plainText)
                == "Résumé\nShip café notes in 東京")
    }

    @Test func userMessagesHaveNoExportPayload() {
        let message = ChatMessage(role: .user, content: "Do not export this question")

        #expect(ChatAnswerExport.payload(for: message, format: .markdown).isEmpty)
        #expect(ChatAnswerExport.payload(for: message, format: .plainText).isEmpty)
    }

    @Test func incompleteReasoningHasNoExportableAnswer() {
        let message = ChatMessage(role: .assistant, content: "<think>Still thinking")

        #expect(ChatAnswerExport.payload(for: message, format: .markdown).isEmpty)
        #expect(ChatAnswerExport.payload(for: message, format: .plainText).isEmpty)
    }

    @Test func markdownWritePreservesUnicodeAndOverwritesExistingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("answer.md")
        try Data("previous answer".utf8).write(to: destination)

        let payload = "## Décisions\n\n- Keep café labels and 東京 notes 🌱\n"
        try ChatAnswerExport.write(payload, to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["answer.md"])
    }

    @Test func writePropagatesFilesystemFailures() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingParent = directory.appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("answer.txt")
        #expect(throws: (any Error).self) {
            try ChatAnswerExport.write("answer", to: missingParent)
        }

        let destinationIsDirectory = directory.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationIsDirectory, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try ChatAnswerExport.write("answer", to: destinationIsDirectory)
        }
    }
}
