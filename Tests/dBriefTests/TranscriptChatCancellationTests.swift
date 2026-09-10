import Foundation
import AppKit
import SwiftUI
import Testing
@testable import dBrief

@Suite("Transcript chat cancellation", .serialized)
@MainActor
struct TranscriptChatCancellationTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
        try #require(condition())
    }

    @Test("Stopping cancels HTTP and preserves a usable conversation", arguments: ["manual", "repetition", "length", "waiting", "view"])
    func stopAndRestart(mode: String) async throws {
        let settings = AppSettings()
        let oldEngine = settings.aiEngine
        let oldEndpoints = settings.aiEndpoints
        let oldDefault = settings.defaultAIEndpointId
        let oldProfiles = settings.profiles
        defer {
            settings.aiEngine = oldEngine
            settings.aiEndpoints = oldEndpoints
            settings.defaultAIEndpointId = oldDefault
            settings.profiles = oldProfiles
        }
        settings.aiEngine = .remoteEndpoint
        settings.aiEndpoints = [Endpoint(name: "Cancellation test", baseURL: "https://chat-\(mode).invalid", modelName: "fixture")]
        settings.defaultAIEndpointId = settings.aiEndpoints[0].id
        for index in settings.profiles.indices {
            settings.profiles[index].overrides.aiEngine = nil
            settings.profiles[index].overrides.aiEndpointId = nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CancellableChatProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        CancellableChatProtocol.stops.reset()
        CancellableChatProtocol.starts.reset()
        let service = TranscriptChatService(transcriptText: "A meeting", speakerLabels: [], appSettings: settings,
            localPlugin: nil, aiService: AIService(session: session))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-stop-\(UUID()).chat.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ChatStore()
        service.enablePersistence(store: store, url: url)
        // Exercise the actual SwiftUI transition as well as the network consumer.
        var chatWindow: NSWindow?
        if mode == "view" {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 750),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TranscriptChatView(chatService: service).frame(width: 420, height: 750))
            chatWindow = window
        }
        defer { chatWindow?.close() }
        let reply = mode == "view" ? CancellableChatProtocol.multilineReply : "Partial answer."
        let first = Task { await service.send("First question") }
        defer { first.cancel() }
        if mode == "waiting" {
            try await waitUntil { service.isStreaming && service.messages.count == 2 && CancellableChatProtocol.starts.count == 1 }
            service.stopGenerating()
            await first.value
            #expect(!service.isStreaming)
            #expect(service.messages.count == 1)
            #expect(service.messages.first?.role == .user)
            #expect(service.streamingError == nil)
            try await waitUntil { CancellableChatProtocol.stops.count == 1 }
            return
        }
        if ["repetition", "length"].contains(mode) {
            try await waitUntil { !service.messages.isEmpty && !service.isStreaming }
            await first.value
            #expect(service.streamingNotice == (mode == "repetition"
                ? "Stopped because the response was repeating itself."
                : "Stopped because the response reached the length limit."))
            #expect(service.streamingError == nil)
            #expect(service.messages.last?.content.isEmpty == false)
            #expect((service.messages.last?.content.count ?? 0) <= 65_536)
            await service.flushPendingSave()
            #expect(try await store.load(from: url)?.messages == service.messages)
            try await waitUntil { CancellableChatProtocol.stops.count == 1 }
            return
        }
        try await waitUntil { service.messages.last?.content == reply }
        chatWindow?.contentView?.layoutSubtreeIfNeeded()
        service.stopGenerating()
        chatWindow?.contentView?.layoutSubtreeIfNeeded()
        #expect(!service.isStreaming)
        #expect(service.messages.last?.content == reply)
        #expect(service.streamingError == nil)
        // Queue the new request immediately, before persistence or old-task cleanup.
        let second = Task { await service.send("Second question") }
        defer { second.cancel() }
        await service.flushPendingSave()
        #expect(try await store.load(from: url)?.messages.last?.content == reply)
        try await waitUntil { service.messages.count == 4 && service.messages.last?.content == reply }
        await first.value
        chatWindow?.contentView?.layoutSubtreeIfNeeded()
        #expect(service.isStreaming)
        service.stopGenerating()
        await second.value
        try await waitUntil { CancellableChatProtocol.stops.count == 2 }
        service.clearMessages()
        #expect(service.messages.isEmpty)
    }
}

private final class CancellableChatProtocol: URLProtocol, @unchecked Sendable {
    static let multilineReply = (1...17).map {
        "**Point \($0): A formatted heading**\n- A detailed explanation with **emphasis** and enough words to wrap in a narrow chat panel.\n"
    }.joined(separator: "\n")
    static let stops = StopCounter()
    static let starts = StopCounter()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("chat-") == true && request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.starts.increment()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let host = request.url!.host!
        guard host != "chat-waiting.invalid" else { return }
        let content: String
        if host == "chat-repetition.invalid" {
            content = String(repeating: "- **20** – again referenced as a monetary value (£20).\n", count: 100)
        } else if host == "chat-length.invalid" {
            content = String(repeating: "x", count: 70_000)
        } else if host == "chat-view.invalid" {
            content = Self.multilineReply
        } else {
            content = "Partial answer."
        }
        let json = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
        client?.urlProtocol(self, didLoad: Data("data: ".utf8) + json + Data("\n\n".utf8))
        // Hold the connection open until the real stream consumer cancels it.
    }
    override func stopLoading() { Self.stops.increment() }
}

private final class StopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func reset() { lock.lock(); defer { lock.unlock() }; value = 0 }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
