import Foundation
import Testing
@testable import dBrief

@Suite("Recording clipboard evidence", .serialized)
@MainActor struct RecordingClipboardTests {
    @Test(arguments: [true, false])
    func recordsThePasteboardResultWithoutContent(accepted: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = PrivacyTrace.Context(receiptURL: folder.appendingPathComponent("receipt.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")))
        let copied = await RecordingClipboard.copy("Private transcript", contextProvider: { context }) { text in
            #expect(text == "Private transcript")
            return accepted
        }
        #expect(copied == accepted)
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].operation.destination == .externallyManaged(provider: .clipboard))
        #expect(receipt.attempts[0].outcome == (accepted ? .succeeded : .failed))
        #expect(!String(decoding: try Data(contentsOf: context.receiptURL), as: UTF8.self).contains("Private transcript"))
    }

    @Test func delayedEarlierCopyDoesNotOverwriteTheLatestUserChoice() async {
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        var clipboard = ""
        let earlier = Task { @MainActor in
            await RecordingClipboard.copy("Earlier", contextProvider: {
                start.yield(())
                for await _ in released { break }
                return nil
            }) { clipboard = $0; return true }
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let later = await RecordingClipboard.copy("Latest", contextProvider: { nil }) { clipboard = $0; return true }
        release.yield(())
        #expect(later)
        #expect(await earlier.value == false)
        #expect(clipboard == "Latest")
    }
}
