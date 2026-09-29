import AppKit
import Foundation
import SwiftUI
import Testing
@testable import dBrief

@MainActor
struct LoadedTranscriptChatFixture {
    let service: TranscriptChatService
    let store: ChatStore
    let sidecarURL: URL
    let history: ChatHistory

    func removeFiles() {
        try? FileManager.default.removeItem(at: sidecarURL)
    }
}

@MainActor
enum TranscriptChatFixtureSupport {
    static func makeLoadedFixture() async throws -> LoadedTranscriptChatFixture {
        let messages = [
            ChatMessage(role: .user, content: "What did the team decide about the launch?"),
            ChatMessage(
                role: .assistant,
                content: "<think>Private fixture reasoning should never appear in an exported answer.</think>\n"
                    + "## Launch decision\n\n"
                    + "- **Keep** the pilot on the current schedule while the access review finishes.\n"
                    + "- Alice will send the revised dates to the customer team.\n\n"
                    + "The group will revisit the rollout after the first support check-in."
            ),
            ChatMessage(role: .user, content: "What will Casey follow up on?"),
            ChatMessage(
                role: .assistant,
                content: "Casey will review the final copy and report any remaining questions."
            ),
        ]
        let history = ChatHistory(messages: messages, engine: "fixture")
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-chat-fixture-\(UUID().uuidString).chat.json")
        let store = ChatStore()
        try await store.save(history, to: sidecarURL)

        let service = TranscriptChatService(
            transcriptText: "The team reviewed the launch schedule and customer access questions.",
            speakerLabels: [],
            appSettings: makeSettingsWithoutPersistentDefaultMutation(),
            localPlugin: nil
        )
        service.enablePersistence(store: store, url: sidecarURL)
        await service.loadPersisted()
        guard service.messages == history.messages else {
            throw FixtureError.persistedHistoryDidNotLoad
        }

        return LoadedTranscriptChatFixture(
            service: service,
            store: store,
            sidecarURL: sidecarURL,
            history: history
        )
    }

    /// AppSettings has one legacy migration that writes `customVocabulary` when
    /// the old prompt exists. Override it only in the volatile argument domain
    /// for this initializer call, then restore the caller's entire domain.
    private static func makeSettingsWithoutPersistentDefaultMutation() -> AppSettings {
        let defaults = UserDefaults.standard
        let originalArgumentDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var isolatedArgumentDomain = originalArgumentDomain
        isolatedArgumentDomain["customVocabulary"] = [String]()
        defaults.setVolatileDomain(isolatedArgumentDomain, forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(originalArgumentDomain, forName: UserDefaults.argumentDomain)
        }
        return AppSettings()
    }

    private enum FixtureError: Error {
        case persistedHistoryDidNotLoad
    }
}

@MainActor
@Suite("Transcript chat export and inspector integration", .serialized)
struct ViewerChatIntegrationTests {
    @Test("Exports only the current selected assistant answer, not reasoning or conversation history")
    func exportsCanonicalAnswerFromLoadedHistory() async throws {
        let fixture = try await TranscriptChatFixtureSupport.makeLoadedFixture()
        defer { fixture.removeFiles() }

        let messages = fixture.history.messages
        let userMessage = try #require(messages.first)
        let selectedAnswer = try #require(messages.dropFirst().first)
        let staleAnswerWithSameID = ChatMessage(
            id: selectedAnswer.id,
            role: .assistant,
            content: "Stale text from before the answer changed."
        )
        let unknownAnswer = ChatMessage(role: .assistant, content: "Not part of this conversation.")

        #expect(fixture.service.canExportAnswer(selectedAnswer))
        #expect(!fixture.service.canExportAnswer(userMessage))
        #expect(!fixture.service.canExportAnswer(unknownAnswer))
        #expect(fixture.service.canExportAnswer(staleAnswerWithSameID))

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-chat-export-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await fixture.service.exportAnswer(
            staleAnswerWithSameID,
            format: .markdown,
            to: destination
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported == selectedAnswer.displayParts.answer)
        #expect(exported.contains("## Launch decision"))
        #expect(!exported.contains("Private fixture reasoning"))
        #expect(!exported.contains("What did the team decide"))
        #expect(!exported.contains("Casey will review"))
        #expect(!exported.contains("Stale text"))
    }

    @Test("An invalidated answer cannot be exported, and a failed write preserves the loaded chat and draft")
    func invalidationAndWriteFailurePreserveSessionState() async throws {
        let fixture = try await TranscriptChatFixtureSupport.makeLoadedFixture()
        defer { fixture.removeFiles() }

        let answer = try #require(fixture.history.messages.dropFirst().first)
        fixture.service.draftInput = "Unsaved follow-up question"
        let messagesBefore = fixture.service.messages
        let sidecarBefore = try await fixture.store.load(from: fixture.sidecarURL)
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-chat-missing-\(UUID().uuidString)", isDirectory: true)
        let destination = missingParent.appendingPathComponent("answer.md")

        var writeFailed = false
        do {
            try await fixture.service.exportAnswer(answer, format: .markdown, to: destination)
        } catch {
            writeFailed = true
        }
        #expect(writeFailed)
        #expect(fixture.service.messages == messagesBefore)
        #expect(fixture.service.draftInput == "Unsaved follow-up question")
        let sidecarAfter = try await fixture.store.load(from: fixture.sidecarURL)
        #expect(sidecarAfter == sidecarBefore)

        fixture.service.invalidateForReprocessing()
        #expect(!fixture.service.canExportAnswer(answer))
        #expect(fixture.service.messages == messagesBefore)
        #expect(fixture.service.draftInput == "Unsaved follow-up question")
    }

    @Test("Hiding and remounting the native chat view retains its draft and persisted messages")
    func chatViewRemountPreservesDraftAndHistory() async throws {
        _ = NSApplication.shared
        let fixture = try await TranscriptChatFixtureSupport.makeLoadedFixture()
        defer { fixture.removeFiles() }

        fixture.service.draftInput = "Keep this unsent question"
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 430, height: 740),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AnyView(TranscriptChatView(chatService: fixture.service)))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        #expect(fixture.service.messages == fixture.history.messages)
        #expect(fixture.service.draftInput == "Keep this unsent question")

        window.contentView = NSHostingView(rootView: AnyView(Text("Chat hidden")))
        try await settle(window)
        #expect(fixture.service.messages == fixture.history.messages)
        #expect(fixture.service.draftInput == "Keep this unsent question")

        window.contentView = NSHostingView(rootView: AnyView(TranscriptChatView(chatService: fixture.service)))
        try await settle(window)
        #expect(fixture.service.messages == fixture.history.messages)
        #expect(fixture.service.draftInput == "Keep this unsent question")
        #expect(!fixture.service.isStreaming)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}
