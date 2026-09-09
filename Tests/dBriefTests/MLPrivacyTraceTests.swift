import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Helper execution privacy evidence")
struct MLPrivacyTraceTests {
    private func fixture() throws -> PrivacyTrace.Context {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ml-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return .init(receiptURL: folder.appendingPathComponent("receipt.json"),
                     store: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")))
    }

    @Test func orderedEvidenceRetainsSwallowedFailuresAndSeparateEmbeddingAttempts() async throws {
        let context = try fixture()
        defer { try? FileManager.default.removeItem(at: context.receiptURL.deletingLastPathComponent()) }
        let trace = PrivacyMLTrace(context: context)
        let diarize = UUID(), first = UUID(), second = UUID()
        trace.receive(.supported(version: 1))
        trace.receive(.started(id: diarize, operation: .speakerDiarization))
        trace.receive(.finished(id: diarize, outcome: .failed))
        trace.receive(.started(id: first, operation: .speakerEmbedding))
        trace.receive(.finished(id: first, outcome: .succeeded))
        trace.receive(.started(id: second, operation: .speakerEmbedding))
        trace.receive(.finished(id: second, outcome: .cancelled))
        await trace.end(crashed: false)
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.map(\.outcome) == [.failed, .succeeded, .cancelled])
        #expect(receipt.attempts.map { $0.operation.destination.provider } == [.speakerKit, .fluidAudio, .fluidAudio])
        #expect(receipt.attempts.allSatisfy { $0.runID == context.runID && $0.operation.data == [.recordingAudio, .metadata] })
        #expect(!receipt.hasGaps)
    }

    @Test(arguments: ["crash", "oldHelper", "missingFinish", "unknownFinish", "duplicateStart"])
    func incompleteOrInvalidHelperEvidenceNeverBecomesSuccess(kind: String) async throws {
        let context = try fixture()
        defer { try? FileManager.default.removeItem(at: context.receiptURL.deletingLastPathComponent()) }
        let trace = PrivacyMLTrace(context: context)
        let id = UUID()
        if kind != "oldHelper" { trace.receive(.supported(version: 1)) }
        if kind == "unknownFinish" { trace.receive(.finished(id: id, outcome: .succeeded)) }
        else if kind != "oldHelper" {
            trace.receive(.started(id: id, operation: .speakerDiarization))
            if kind == "duplicateStart" { trace.receive(.started(id: id, operation: .speakerEmbedding)) }
        }
        await trace.end(crashed: kind == "crash")
        let marked = await context.store.hasUnpersistedGap(at: context.receiptURL)
        let loaded = try await context.store.load(from: context.receiptURL)
        #expect(marked || loaded?.hasGaps == true)
        #expect(try await context.store.load(from: context.receiptURL)?.attempts.allSatisfy { !$0.isConfirmedSuccess } ?? true)
    }

    @Test(arguments: ["privacy-failure", "privacy-malformed"])
    func actualHelperFramesAreEvidenceNotCallResults(mode: String) async throws {
        let context = try fixture()
        let folder = context.receiptURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                          supportBase: folder, environment: ["STUB_MODE": mode])
        let event = try await PrivacyTrace.$context.withValue(context) {
            try await connection.call(.parakeetTranscribe(path: "/private-name.wav", modelVariant: "v3", diarize: true))
        }
        await connection.shutdown()
        guard case .transcriptionResult = event else { Issue.record("Privacy frame consumed as result"); return }
        if mode == "privacy-malformed" {
            let receipt = try await context.store.load(from: context.receiptURL)
            let marked = await context.store.hasUnpersistedGap(at: context.receiptURL)
            #expect(marked || receipt?.hasGaps == true)
            #expect(receipt?.attempts.isEmpty ?? true)
            return
        }
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.map(\.outcome) == [.failed])
        #expect(!receipt.hasGaps)
        #expect(!String(decoding: try Data(contentsOf: context.receiptURL), as: UTF8.self).contains("private-name"))
    }
}
