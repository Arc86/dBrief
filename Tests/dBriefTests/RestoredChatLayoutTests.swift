import AppKit
import SwiftUI
import Testing
@testable import dBrief

@Suite("Restored chat window layout", .serialized)
@MainActor
struct RestoredChatLayoutTests {
    @Test("Opening a recording with a saved multiline chat keeps the visible window responsive")
    func openSavedConversation() async throws {
        _ = NSApplication.shared
        let settings = AppSettings()
        let service = TranscriptChatService(transcriptText: "Transcript", speakerLabels: [], appSettings: settings, localPlugin: nil)
        let reply = (1...17).map {
            "**\($0). A frequently asked question about this recording?**\n- A detailed answer with enough words to wrap across several lines in the assistant column.\n"
        }.joined(separator: "\n")
        var history = ChatHistory(messages: [
            ChatMessage(role: .user, content: "Summarize this transcript"),
            ChatMessage(role: .assistant, content: "Error: Invalid response from AI server."),
            ChatMessage(role: .user, content: "Create a FAQ based on this transcript."),
            ChatMessage(role: .assistant, content: reply),
            ChatMessage(role: .user, content: "Summarize this transcript"),
        ])
        let fixtureDirectory = ProcessInfo.processInfo.environment["DBRIEF_LAYOUT_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let fixtureDirectory {
            history = try JSONDecoder().decode(ChatHistory.self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent("exact.chat.json")))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restore-layout-\(UUID()).chat.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ChatStore()
        try await store.save(history, to: url)
        service.enablePersistence(store: store, url: url)
        var insights = RecordingInsights(summary: String(repeating: "A discussion point about the recording with sufficient detail to wrap across several lines.\n\n", count: 40),
            actionItems: ["No action items identified"], tags: ["topic", "discussion"], sentiment: "Neutral", markdownPath: nil)
        if let fixtureDirectory {
            insights = try JSONDecoder().decode(RecordingInsights.self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent("exact.insights.json")))
        }
        let root = NavigationSplitView {
            Text("Selected recording").frame(width: 320)
        } detail: {
            VStack(spacing: 0) {
                Text("Saved recording").font(.title2).padding()
                Divider()
                HStack(spacing: 0) {
                    SummaryView(insights: insights, isGenerating: false, canGenerate: false)
                    Divider()
                    VStack(spacing: 0) {
                        Text("dBrief Assistant").padding()
                        Divider()
                        TranscriptChatView(chatService: service)
                    }.frame(width: 480)
                }
            }
        }.frame(width: 1920, height: 1150)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1920, height: 1150),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        await service.loadPersisted()
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        #expect(service.messages == history.messages)
        #expect(window.isVisible)
    }
}
